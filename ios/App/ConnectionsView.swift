import SwiftUI

/// Соединения как в настольном клиенте: адрес и порт, откуда, протокол, объём,
/// сработавшее правило и через какой сервер. Фильтры — правило, сеть и поиск;
/// нажатие открывает адрес, а из него можно сразу добавить правило в профиль маршрутизации.
struct ConnectionsView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var router: AppRouter

    @State private var connections: [ClashApi.Connection] = []
    @State private var query = ""
    @State private var networkFilter = 0        // 0 — все, 1 — tcp, 2 — udp
    @State private var ruleFilter = ""          // "" — все
    @State private var outboundFilter = ""      // "" — все
    @State private var refreshed = Date()
    /// Один активный лист на весь экран: несколько `.sheet` на одном виде в iOS 15 конфликтуют.
    @State private var activeSheet: ConnectionsSheet?

    /// Пауза: сбор соединений останавливается, список замирает на моменте нажатия —
    /// вместе с теми соединениями, что закрылись в последние пять секунд.
    /// Окно графика: 1/2/5/10 минут. Пауза — справа от кнопок окна.
    @State private var window: TrafficWindow = .two
    /// Сэмплы трафика: раз в опрос, хранится десять минут.
    @State private var samples: [TrafficSample] = []
    /// Счётчики соединений с прошлого опроса — по ним считаются скорости.
    @State private var counters: [String: TrafficCounters] = [:]
    @State private var lastSampleAt: Date?
    @State private var paused = false
    @State private var recentlyClosed: [ClashApi.Connection] = []
    @State private var closedAt: [String: Date] = [:]
    @State private var notice = ""

    /// Опрос Clash API — только пока экран на виду. Раньше это был Timer.publish: он
    /// продолжал стучаться в 19090 и после ухода с вкладки, в том числе во время серии
    /// проверок, когда ядро перезапускается десятки раз.
    @State private var polling: Task<Void, Never>?

    private var ruleNames: [String] {
        var names: [String] = []
        for item in connections where !names.contains(item.rule) { names.append(item.rule) }
        return names.sorted()
    }

    private var outboundNames: [String] {
        var names: [String] = []
        for item in connections where !names.contains(item.outbound) { names.append(item.outbound) }
        return names.sorted()
    }

    private var filterActive: Bool {
        !query.isEmpty || networkFilter != 0 || !ruleFilter.isEmpty || !outboundFilter.isEmpty
    }

    private var activeIDs: Set<String> { Set(connections.map { $0.id }) }

    /// Что показываем: активные сверху (по объёму), остановленные — снизу,
    /// в порядке «чем позже остановилось, тем выше».
    private var shown: [ClashApi.Connection] {
        var merged = connections
        for item in recentlyClosed where !merged.contains(where: { $0.id == item.id }) {
            merged.append(item)
        }
        return merged.sorted { left, right in
            let leftActive = activeIDs.contains(left.id)
            let rightActive = activeIDs.contains(right.id)
            if leftActive != rightActive { return leftActive }
            if leftActive { return left.download + left.upload > right.download + right.upload }
            let leftClosed = closedAt[left.id] ?? .distantPast
            let rightClosed = closedAt[right.id] ?? .distantPast
            return leftClosed > rightClosed
        }
    }

    private var visible: [ClashApi.Connection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return shown.filter { item in
            if !ruleFilter.isEmpty, item.rule != ruleFilter { return false }
            if !outboundFilter.isEmpty, item.outbound != outboundFilter { return false }
            switch networkFilter {
            case 1: if item.network.lowercased() != "tcp" { return false }
            case 2: if item.network.lowercased() != "udp" { return false }
            default: break
            }
            guard !text.isEmpty else { return true }
            return item.host.lowercased().contains(text)
                || item.ip.lowercased().contains(text)
                || String(item.port).contains(text)
                || item.outbound.lowercased().contains(text)
        }
    }

    private var totalUp: Int64 {
        var total: Int64 = 0
        for item in shown { total += Int64(item.upload) }
        return total
    }

    private var totalDown: Int64 {
        var total: Int64 = 0
        for item in shown { total += Int64(item.download) }
        return total
    }

    var body: some View {
        NavigationView {
            List {
                if paused || !notice.isEmpty { statusSection }
                trafficSection
                summarySection
                if filterActive { activeFilterSection }
                listSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Соединения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                refresh()
                startPolling()
            }
            .onDisappear {
                polling?.cancel()
                polling = nil
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .detail(let item):
                    ConnectionDetailView(connection: item) { attr, value, title in
                        activeSheet = nil
                        // Даём шторке закрыться, иначе iOS 15 проглатывает следующий лист.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            router.openRouting(with: RouteInsertPrefill(title: title, attr: attr, value: value))
                        }
                    }
                case .filter:
                    ConnectionsFilterSheet(query: $query,
                                           network: $networkFilter,
                                           rule: $ruleFilter,
                                           outbound: $outboundFilter,
                                           rules: ruleNames,
                                           outbounds: outboundNames)
                case .export(let url):
                    ShareSheet(items: [url])
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    paused.toggle()
                    notice = paused ? "пауза: список не обновляется" : ""
                } label: {
                    Label(paused ? "Продолжить" : "Пауза",
                          systemImage: paused ? "play.fill" : "pause.fill")
                }
                Button {
                    activeSheet = .filter
                } label: {
                    Label(filterActive ? "Фильтр (включён)" : "Фильтр",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                Divider()
                Button {
                    copySummary()
                } label: {
                    Label("Скопировать", systemImage: "doc.on.doc")
                }
                Button {
                    export()
                } label: {
                    Label("Экспорт в txt", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var statusSection: some View {
        Section {
            if paused {
                Label("Пауза — список замер на \(Self.time.string(from: refreshed))", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            if !notice.isEmpty {
                Text(notice).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var activeFilterSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundColor(Theme.accent)
                Text(filterSummary).font(.caption2)
                Spacer()
                Button("Сбросить") {
                    query = ""
                    networkFilter = 0
                    ruleFilter = ""
                    outboundFilter = ""
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Показано \(visible.count) из \(shown.count)")
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !query.isEmpty { parts.append("«\(query)»") }
        if networkFilter == 1 { parts.append("tcp") }
        if networkFilter == 2 { parts.append("udp") }
        if !ruleFilter.isEmpty { parts.append("правило: \(ruleFilter)") }
        if !outboundFilter.isEmpty { parts.append("сервер: \(outboundFilter)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Трафик

    /// Карточка как «Live graphs»: окно 1/2/5/10 минут, пауза справа от него,
    /// текущие скорости по выходам и график за выбранное окно.
    private var trafficSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Трафик").font(.headline)
                    Spacer()
                    ForEach(TrafficWindow.allCases) { item in
                        Button(item.rawValue) { window = item }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(window == item ? Theme.accent.opacity(0.18) : Color.clear)
                            .foregroundColor(window == item ? Theme.accent : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Button {
                        paused.toggle()
                        notice = paused ? "пауза: список и график замерли" : ""
                        if !paused { lastSampleAt = nil; counters.removeAll() }
                    } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.semibold))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 12) {
                    Label(Self.rate(lastDown), systemImage: "arrow.down")
                        .foregroundColor(Theme.accent)
                    Label(Self.rate(lastUp), systemImage: "arrow.up")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("↓ " + Self.size(windowBytes.down) + " · ↑ " + Self.size(windowBytes.up))
                        .foregroundColor(.secondary)
                }
                .font(.caption.weight(.medium))

                if !outboundRows.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(outboundRows, id: \.name) { row in
                            HStack {
                                Text(row.name).lineLimit(1)
                                Spacer()
                                Text(Self.rate(row.down))
                                    .foregroundColor(Theme.accent)
                                    .frame(width: 88, alignment: .trailing)
                                Text(Self.rate(row.up))
                                    .foregroundColor(.secondary)
                                    .frame(width: 88, alignment: .trailing)
                            }
                            .font(.caption2)
                        }
                    }
                }

                TrafficGraph(points: windowSamples.map { ($0.at, $0.down, $0.up) },
                             start: windowStart, end: windowEnd,
                             peakLabel: Self.rate(max(lastDown, lastUp)))

            }
            .padding(.vertical, 2)
        } footer: {
            Text("Окно " + window.rawValue + " · точек " + String(windowSamples.count)
                 + ". Входящий — цвет акцента, исходящий — серый. Сводка целиком — в меню «⋯»: «Скопировать» и «Экспорт в txt» (трафик, выходы, правила, все соединения).")
        }
    }

    private var summarySection: some View {
        Section {
            HStack {
                Label("↑ " + Self.size(totalUp), systemImage: "arrow.up")
                    .foregroundColor(.orange)
                Spacer()
                Label("↓ " + Self.size(totalDown), systemImage: "arrow.down")
                    .foregroundColor(.green)
            }
            .font(.footnote.weight(.medium))
            HStack {
                Text("Соединений")
                Spacer()
                Text(String(shown.count)).foregroundColor(.secondary)
            }
            .font(.footnote)
            HStack {
                Text("Обновлено")
                Spacer()
                Text(Self.time.string(from: refreshed)).foregroundColor(.secondary)
            }
            .font(.footnote)
        } header: {
            Text("Сейчас")
        }
    }

    private var listSection: some View {
        Section {
            if shown.isEmpty {
                Text(engine.running
                     ? "живых соединений нет"
                     : "ядро выключено — поднимите туннель на вкладке «Серверы»")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(visible, id: \.id) { item in
                Button {
                    activeSheet = .detail(item)
                } label: {
                    connectionRow(item: item)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        insertFromRow(item)
                    } label: {
                        Label("В правило", systemImage: "arrow.triangle.branch")
                    }
                    .tint(Theme.accent)
                }
            }
        } header: {
            Text("Соединения · " + String(activeIDs.count) + " активных")
        } footer: {
            Text("Остановленные висят минуту и гаснут, если трафик не возобновился; возобновился — снова активны.")
        }
    }

    /// Свайп по строке: сразу в «добавить правило», без открытия подробностей.
    private func insertFromRow(_ item: ClashApi.Connection) {
        let host = item.host.trimmingCharacters(in: .whitespacesAndNewlines)
        router.openRouting(with: RouteInsertPrefill(
            title: host.isEmpty ? "IP → правило" : "домен → правило",
            attr: host.isEmpty ? "ip_cidr" : "domain",
            value: host.isEmpty ? item.ip : host))
    }

    /// Строка: точка активности, адрес с портом, сколько живёт, правило и выход.
    private func connectionRow(item: ClashApi.Connection) -> some View {
        let active = activeIDs.contains(item.id)
        return HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(active ? Color.green : Color(uiColor: .tertiaryLabel))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.destination)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(ruleText(item))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(item.outbound)
                        .font(.caption2)
                        .foregroundColor(active ? Theme.accent : Color(uiColor: .tertiaryLabel))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(durationText(item))
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(active ? .secondary : Color(uiColor: .tertiaryLabel))
                .frame(minWidth: 52, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.vertical, 4)
    }

    /// Активное — до сейчас, остановленное — до момента, когда пропало из опроса.
    private func durationText(_ item: ClashApi.Connection) -> String {
        Self.duration(item.start, to: closedAt[item.id] ?? Date())
    }

    private func networkText(_ item: ClashApi.Connection) -> String {
        var text = item.network.isEmpty ? "—" : item.network
        if !item.process.isEmpty { text += "(\(item.process))" }
        return text
    }

    private func ruleText(_ item: ClashApi.Connection) -> String {
        guard !item.rulePayload.isEmpty else { return item.rule }
        return item.rule + "[" + item.rulePayload + "]"
    }

    // MARK: - Сбор статистики

    /// Правый край окна — последний сэмпл, чтобы график не «уезжал» между опросами.
    private var windowEnd: Date { samples.last?.at ?? Date() }

    private var windowStart: Date { windowEnd.addingTimeInterval(-window.seconds) }

    private var windowSamples: [TrafficSample] {
        samples.filter { $0.at >= windowStart }
    }

    private var lastDown: Double { samples.last?.down ?? 0 }
    private var lastUp: Double { samples.last?.up ?? 0 }

    private var windowBytes: (down: Int64, up: Int64) {
        windowSamples.reduce((0, 0)) { ($0.0 + $1.bytesDown, $0.1 + $1.bytesUp) }
    }

    private var windowBytesByOutbound: [(name: String, down: Int64, up: Int64)] {
        var totals: [String: TrafficCounters] = [:]
        for sample in windowSamples {
            for (name, bytes) in sample.bytesByOutbound {
                var row = totals[name] ?? TrafficCounters(up: 0, down: 0)
                row.up += bytes.up
                row.down += bytes.down
                totals[name] = row
            }
        }
        return totals.map { (name: $0.key, down: $0.value.down, up: $0.value.up) }
            .filter { $0.down + $0.up > 0 }
            .sorted { $0.down + $0.up > $1.down + $1.up }
    }

    /// Скорости по выходам за последний сэмпл — то, что видно строками под шапкой.
    private var outboundRows: [(name: String, down: Double, up: Double)] {
        guard let last = samples.last else { return [] }
        return last.byOutbound.map { (name: $0.key, down: $0.value.down, up: $0.value.up) }
            .sorted { $0.down + $0.up > $1.down + $1.up }
            .prefix(5)
            .map { $0 }
    }

    /// Сводка по правилам: сколько соединений и сколько байт прошло через каждое.
    private func ruleTotals(_ list: [ClashApi.Connection])
        -> [(name: String, count: Int, down: Int64, up: Int64)] {
        var totals: [String: (count: Int, down: Int64, up: Int64)] = [:]
        for item in list {
            let key = ruleText(item)
            var row = totals[key] ?? (0, 0, 0)
            row.count += 1
            row.down += Int64(item.download)
            row.up += Int64(item.upload)
            totals[key] = row
        }
        return totals.map { (name: $0.key, count: $0.value.count, down: $0.value.down, up: $0.value.up) }
            .sorted { $0.count > $1.count }
    }

    /// Один сэмпл на опрос: дельты счётчиков делим на прошедшее время.
    private func recordSample(_ list: [ClashApi.Connection], at now: Date) {
        var next: [String: TrafficCounters] = [:]
        var byOutbound: [String: TrafficCounters] = [:]
        var bytesDown: Int64 = 0
        var bytesUp: Int64 = 0
        for item in list {
            let down = Int64(item.download)
            let up = Int64(item.upload)
            next[item.id] = TrafficCounters(up: up, down: down)
            // Считаем только тех, кого видели в прошлом опросе: счётчики закрытых
            // соединений исчезают, и разница «минус всё» дала бы ложный всплеск.
            guard let previous = counters[item.id] else { continue }
            let deltaDown = max(down - previous.down, 0)
            let deltaUp = max(up - previous.up, 0)
            bytesDown += deltaDown
            bytesUp += deltaUp
            var row = byOutbound[item.outbound] ?? TrafficCounters(up: 0, down: 0)
            row.down += deltaDown
            row.up += deltaUp
            byOutbound[item.outbound] = row
        }
        counters = next
        let elapsed = now.timeIntervalSince(lastSampleAt ?? now)
        lastSampleAt = now
        // После паузы или возврата на вкладку разница накопилась за минуты —
        // такой сэмпл только испортил бы график.
        guard elapsed > 0, elapsed < 10 else { return }
        samples.append(TrafficSample(
            at: now,
            down: Double(bytesDown) / elapsed,
            up: Double(bytesUp) / elapsed,
            bytesDown: bytesDown,
            bytesUp: bytesUp,
            byOutbound: byOutbound.mapValues {
                TrafficRates(down: Double($0.down) / elapsed, up: Double($0.up) / elapsed)
            },
            bytesByOutbound: byOutbound))
        let horizon = now.addingTimeInterval(-610)
        if let first = samples.first, first.at < horizon {
            samples.removeAll { $0.at < horizon }
        }
    }

    static func rate(_ value: Double) -> String {
        let bytes = max(Int64(value.rounded()), 0)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/с"
    }

    private func startPolling() {
        polling?.cancel()
        polling = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                refresh()
            }
        }
    }

    private func refresh() {
        // На паузе список не трогаем: он показывает соединения на момент нажатия.
        guard !paused else { return }
        guard engine.running else {
            connections = []
            return
        }
        Task {
            let list = await ClashApi.connections()
            await MainActor.run {
                guard !paused else { return }
                // Соединения, закрывшиеся с прошлого опроса, держим ещё пять секунд: на паузе
                // видно и то, что только что оборвалось, — иначе строка исчезает до нажатия.
                let now = Date()
                let currentIDs = Set(list.map { $0.id })
                // Соединение из списка закрытых снова в опросе — трафик возобновился.
                recentlyClosed.removeAll { currentIDs.contains($0.id) }
                for item in connections where !currentIDs.contains(item.id) {
                    if !recentlyClosed.contains(where: { $0.id == item.id }) {
                        recentlyClosed.append(item)
                        closedAt[item.id] = now
                    }
                }
                recentlyClosed.removeAll { item in
                    guard let closed = closedAt[item.id] else { return true }
                    return now.timeIntervalSince(closed) > 60
                }
                if recentlyClosed.count > 80 {
                    recentlyClosed = Array(recentlyClosed.suffix(80))
                }

                connections = list.count > 400 ? Array(list.prefix(400)) : list
                recordSample(list, at: now)
                refreshed = Date()
                if !ruleFilter.isEmpty, !list.contains(where: { $0.rule == ruleFilter }) {
                    ruleFilter = ""
                }
                if !outboundFilter.isEmpty, !list.contains(where: { $0.outbound == outboundFilter }) {
                    outboundFilter = ""
                }
            }
        }
    }

    /// Таблица в текст: одна строка на соединение, читается и в чате, и в файле.
    private func plainText(_ list: [ClashApi.Connection]) -> String {
        var lines: [String] = []
        lines.append("Соединения · \(Self.fileStamp.string(from: Date())) · окно \(window.rawValue) · всего \(list.count)")
        let bytes = windowBytes
        lines.append("Трафик за \(window.rawValue): ↓ \(Self.size(bytes.down)) ↑ \(Self.size(bytes.up))")
        let byOutbound = windowBytesByOutbound
        if !byOutbound.isEmpty {
            lines.append("По выходам:")
            for row in byOutbound {
                lines.append("  " + row.name + ": ↓ " + Self.size(row.down) + " ↑ " + Self.size(row.up))
            }
        }
        let rulesSummary = ruleTotals(list)
        if !rulesSummary.isEmpty {
            lines.append("Правила:")
            for row in rulesSummary {
                lines.append("  " + row.name + " → " + String(row.count) + " соединений, ↓ "
                             + Self.size(row.down) + " ↑ " + Self.size(row.up))
            }
        }
        lines.append("Соединения:")
        for (index, item) in list.enumerated() {
            var parts: [String] = []
            parts.append(item.destination)
            if !item.source.isEmpty { parts.append("из " + item.source) }
            if !item.proto.isEmpty { parts.append(item.proto) }
            parts.append(networkText(item))
            parts.append("↑ " + Self.size(Int64(item.upload)) + " ↓ " + Self.size(Int64(item.download)))
            parts.append(ruleText(item))
            parts.append(item.outbound)
            lines.append(String(index + 1) + ". " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Сводка в буфер: трафик за окно, выходы, правила и все соединения.
    private func copySummary() {
        UIPasteboard.general.string = plainText(visible)
        notice = "скопировано: " + String(visible.count) + " соединений"
    }

    private func export() {
        let text = plainText(visible)
        let name = "throne-connections-" + Self.fileStamp.string(from: Date()) + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            activeSheet = .export(url)
        } catch {
            notice = "экспорт не удался: " + error.localizedDescription
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ start: Date?) -> String {
        duration(start, to: Date())
    }

    /// Длительность до конкретного момента — для остановленных соединений это время закрытия.
    static func duration(_ start: Date?, to end: Date) -> String {
        guard let start else { return "—" }
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 {
            return String(hours) + ":" + String(format: "%02d:%02d", minutes, rest)
        }
        return String(minutes) + ":" + String(format: "%02d", rest)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Для имени файла экспорта: дата и минута.
    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}

/// Листы экрана «Соединения»: подробности, фильтр и файл экспорта.
enum ConnectionsSheet: Identifiable {
    case detail(ClashApi.Connection)
    case filter
    case export(URL)

    var id: String {
        switch self {
        case .detail(let item): return "detail-" + item.id
        case .filter: return "filter"
        case .export(let url): return "export-" + url.lastPathComponent
        }
    }
}

/// Окно фильтра соединений: адрес, сеть, правило и выходной сервер.
struct ConnectionsFilterSheet: View {
    @Environment(\.presentationMode) private var presentation

    @Binding var query: String
    @Binding var network: Int
    @Binding var rule: String
    @Binding var outbound: String

    let rules: [String]
    let outbounds: [String]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("домен, IP или порт", text: $query)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("Адрес")
                }

                Section {
                    Picker("Сеть", selection: $network) {
                        Text("Все").tag(0)
                        Text("tcp").tag(1)
                        Text("udp").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Picker("Правило", selection: $rule) {
                        Text("все").tag("")
                        ForEach(rules, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Picker("Выходной сервер", selection: $outbound) {
                        Text("все").tag("")
                        ForEach(outbounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                } header: {
                    Text("Условия")
                } footer: {
                    Text("Значения берутся из живых соединений: правила и сервера, которых сейчас нет в списке, сюда не попадают.")
                }

                Section {
                    Button("Сбросить фильтр") {
                        query = ""
                        network = 0
                        rule = ""
                        outbound = ""
                    }
                }
            }
            .navigationTitle("Фильтр")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Подробности соединения: адрес, порт и кнопки «добавить в правило».
struct ConnectionDetailView: View {
    @Environment(\.presentationMode) private var presentation

    let connection: ClashApi.Connection
    let onInsert: (_ attr: String, _ value: String, _ title: String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        insert(attr: "domain", value: connection.host, title: "домен → правило")
                    } label: {
                        row(title: connection.host.isEmpty ? "—" : connection.host,
                            subtitle: "домен → правило")
                    }
                    .disabled(connection.host.isEmpty)

                    Button {
                        insert(attr: "ip_cidr", value: connection.ip, title: "IP → правило")
                    } label: {
                        row(title: connection.ip.isEmpty ? "—" : connection.ip,
                            subtitle: "IP → правило")
                    }
                    .disabled(connection.ip.isEmpty)

                    Button {
                        insert(attr: "port", value: String(connection.port), title: "порт → правило")
                    } label: {
                        row(title: connection.port > 0 ? String(connection.port) : "—",
                            subtitle: "порт → правило")
                    }
                    .disabled(connection.port <= 0)
                } header: {
                    Text("Нажмите, чтобы добавить в маршрутизацию")
                } footer: {
                    Text("Откроется добавление в маршрутизацию: выберете профиль и папку с атрибутами — значение ляжет туда.")
                }

                Section {
                    HStack {
                        Text("Источник")
                        Spacer()
                        Text(connection.source.isEmpty ? "—" : connection.source)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Сеть")
                        Spacer()
                        Text(connection.network.isEmpty ? "—" : connection.network)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Протокол")
                        Spacer()
                        Text(connection.proto.isEmpty ? "—" : connection.proto)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if !connection.process.isEmpty {
                        HStack {
                            Text("Процесс")
                            Spacer()
                            Text(connection.process)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Text("Правило")
                        Spacer()
                        Text(connection.rule)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if !connection.rulePayload.isEmpty {
                        HStack {
                            Text("Значение правила")
                            Spacer()
                            Text(connection.rulePayload)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Text("Outbound")
                        Spacer()
                        Text(connection.outbound)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Трафик")
                        Spacer()
                        Text("↑ " + ConnectionsView.size(Int64(connection.upload))
                             + " · ↓ " + ConnectionsView.size(Int64(connection.download)))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Длительность")
                        Spacer()
                        Text(ConnectionsView.duration(connection.start))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Соединение")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Соединение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(title: String, subtitle: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(Theme.accent)
        }
    }

    private func insert(attr: String, value: String, title: String) {
        onInsert(attr, value, title)
        presentation.wrappedValue.dismiss()
    }
}

// MARK: - Статистика трафика

/// Окно графика: кнопки «1м 2м 5м 10м» в карточке трафика.
enum TrafficWindow: String, CaseIterable, Identifiable {
    case one = "1м", two = "2м", five = "5м", ten = "10м"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .one: return 60
        case .two: return 120
        case .five: return 300
        case .ten: return 600
        }
    }
}

struct TrafficCounters {
    var up: Int64
    var down: Int64
}

struct TrafficRates {
    var down: Double
    var up: Double
}

/// Сэмпл трафика: скорости для графика и байты за интервал для сводки.
struct TrafficSample: Identifiable {
    let id = UUID()
    let at: Date
    let down: Double
    let up: Double
    let bytesDown: Int64
    let bytesUp: Int64
    let byOutbound: [String: TrafficRates]
    let bytesByOutbound: [String: TrafficCounters]
}

/// График за выбранное окно: X — реальное время, Y — общая шкала,
/// входящий — акцентом, исходящий — серым.
struct TrafficGraph: View {
    let points: [(at: Date, down: Double, up: Double)]
    let start: Date
    let end: Date
    let peakLabel: String

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                    grid(size: geometry.size)
                    line(incoming: true, peak: peak, size: geometry.size, color: Theme.accent)
                    line(incoming: false, peak: peak, size: geometry.size, color: .gray)
                    Text("пик " + peakLabel)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
            }
            .frame(height: 96)
            HStack {
                Text(agoLabel(start))
                Spacer()
                Text(agoLabel(start.addingTimeInterval(end.timeIntervalSince(start) / 2)))
                Spacer()
                Text("сейчас")
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
        }
    }

    private var peak: Double {
        let maximum = points.map { max($0.down, $0.up) }.max() ?? 0
        return maximum > 0 ? maximum : 1
    }

    /// Три горизонтальные линии — чтобы видеть масштаб.
    private func grid(size: CGSize) -> some View {
        Path { path in
            for step in 1...3 {
                let y = size.height * CGFloat(step) / 4
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
    }

    /// X считается по времени: иначе смена окна не видна — линии просто растягивались.
    private func line(incoming: Bool, peak: Double, size: CGSize, color: Color) -> some View {
        let span = max(end.timeIntervalSince(start), 1)
        return Path { path in
            guard points.count > 1 else { return }
            for (index, point) in points.enumerated() {
                let x = CGFloat(max(min(point.at.timeIntervalSince(start) / span, 1), 0)) * size.width
                let value = incoming ? point.down : point.up
                let ratio = CGFloat(value / peak)
                let y = size.height - ratio * (size.height - 8) - 4
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
    }

    /// Не абсолютное время, а «сколько назад»: −2 мин, −30 с, сейчас.
    private func agoLabel(_ date: Date) -> String {
        let seconds = Int(end.timeIntervalSince(date).rounded())
        if seconds <= 5 { return "сейчас" }
        if seconds < 60 { return "−" + String(seconds) + " с" }
        let minutes = seconds / 60
        if minutes < 60 { return "−" + String(minutes) + " мин" }
        return "−" + String(minutes / 60) + " ч"
    }
}




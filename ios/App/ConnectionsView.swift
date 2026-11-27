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
    /// Статистику ведёт общий сборщик: он тикает всегда, а не только при открытой
    /// вкладке, и отдаёт одинаковые цифры и «Серверам», и «Соединениям».
    @ObservedObject private var sampler = TrafficSampler.shared
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
                sessionSection
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
                    ConnectionDetailView(connection: item,
                                         folderName: folderName(item),
                                         exitName: exitName(item)) { attr, value, title in
                        activeSheet = nil
                        LogStore.shared.append("соединения: переносим «" + value + "» в правило")
                        // Один и тот же лист на одном уровне: закрылись подробности —
                        // открылся выбор профиля и папки.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            activeSheet = .insert(RouteInsertPrefill(title: title, attr: attr,
                                                                     value: value))
                        }
                    }
                case .insert(let prefill):
                    RouteInsertSheet(prefill: prefill)
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
                Divider()
                Button {
                    sampler.clearHistory()
                    notice = "история графика очищена"
                } label: {
                    Label("Очистить график", systemImage: "trash")
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
    /// Сколько прошло с запуска ядра — отдельной строкой между графиком и списком.
    private var sessionSection: some View {
        Section {
            Text("С включения ядра: ↓ " + Self.size(sampler.sessionDown)
                 + " · ↑ " + Self.size(sampler.sessionUp))
                .font(.caption2)
                .foregroundColor(.secondary)
                .listRowBackground(Color.clear)
        }
    }

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
                    } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.semibold))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderless)
                }

                // Крупно — сколько прошло за выбранный промежуток: окно графика
                // и это значение относятся к одному и тому же времени.
                Text("За " + window.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                HStack(spacing: 16) {
                    Label(Self.size(windowBytes.down), systemImage: "arrow.down")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(Theme.accent)
                    Label(Self.size(windowBytes.up), systemImage: "arrow.up")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                }

                TrafficGraph(points: windowSamples.map { ($0.at, $0.down, $0.up) },
                             start: windowStart, end: windowEnd)

            }
            .padding(.vertical, 2)
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
            HStack(spacing: 6) {
                Text("Соединения · " + String(activeIDs.count) + " активных")
                Spacer(minLength: 6)
                Text("↓ " + Self.rate(lastDown))
                    .foregroundColor(Theme.accent)
                Text("↑ " + Self.rate(lastUp))
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Остановленные висят десять секунд и гаснут, если трафик не возобновился; возобновился — снова активны.")
        }
    }

    /// Свайп по строке: сразу в «добавить правило», без открытия подробностей.
    private func insertFromRow(_ item: ClashApi.Connection) {
        let host = item.host.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSheet = .insert(RouteInsertPrefill(
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
                    Text(folderName(item))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if !item.isService {
                        Text(exitName(item))
                            .font(.caption2)
                            .foregroundColor(active ? Theme.accent : Color(uiColor: .tertiaryLabel))
                            .lineLimit(1)
                    }
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

    /// Имя папки из профиля маршрутизации, чьё значение сработало:
    /// в конфиг ядра имя папки не попадает, ищем по значению правила.
    private func folderName(_ item: ClashApi.Connection) -> String {
        if item.isService { return "Служебное подключение" }
        // Ядро отдаёт правило строкой вида «domain_suffix=cloudflare.com => route(s0)»,
        // а rulePayload всегда пустой — поэтому папку ищем по разобранному правилу.
        if let parsed = parsedRule(item) {
            for folder in rules.plan.rules {
                for attribute in folder.attrs
                where attribute.attr == parsed.attr && attribute.values.contains(parsed.value) {
                    return folder.name
                }
            }
        }
        if !item.rulePayload.isEmpty {
            for folder in rules.plan.rules {
                for attribute in folder.attrs where attribute.values.contains(item.rulePayload) {
                    return folder.name
                }
            }
        }
        // Ни одна папка не совпала: сработал outbound по умолчанию.
        if item.rule.isEmpty || item.rule.lowercased() == "final"
            || item.rule.lowercased() == "match" {
            return "по умолчанию"
        }
        if let parsed = parsedRule(item) {
            return parsed.attr + " " + parsed.value
        }
        return item.rule
    }

    /// Разбор правила ядра: «domain_suffix=cloudflare.com => route(s0)» → («domain_suffix», «cloudflare.com»).
    private func parsedRule(_ item: ClashApi.Connection) -> (attr: String, value: String)? {
        let text = item.rule
        guard let arrow = text.range(of: " => ") else { return nil }
        let condition = String(text[text.startIndex..<arrow.lowerBound])
        guard let equals = condition.firstIndex(of: "=") else { return nil }
        let attr = String(condition[condition.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(condition[condition.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !attr.isEmpty, !value.isEmpty else { return nil }
        return (attr, value)
    }

    /// Выход: активный сервер — proxy, напрямую — direct, конкретный сервер — его имя.
    private func exitName(_ item: ClashApi.Connection) -> String {
        // Для замера пинга выход не показываем: строка целиком про служебное соединение.
        if item.isService { return "" }
        let tag = item.outbound
        if tag.isEmpty { return "—" }
        if tag == "direct" || tag == "reject" { return tag }
        if tag == engine.selectedTag { return "proxy" }
        return engine.tagNames[tag] ?? tag
    }

    private func ruleText(_ item: ClashApi.Connection) -> String {
        guard !item.rulePayload.isEmpty else { return item.rule }
        return item.rule + "[" + item.rulePayload + "]"
    }

    // MARK: - Сбор статистики

    /// Правый край окна — «сейчас»; на паузе замирает на последней точке.
    private var windowEnd: Date { paused ? (sampler.samples.last?.at ?? Date()) : Date() }

    private var windowStart: Date { windowEnd.addingTimeInterval(-window.seconds) }

    private var windowSamples: [TrafficSample] {
        sampler.samples(in: window.seconds, until: windowEnd)
    }

    private var lastDown: Double { sampler.currentDown }
    private var lastUp: Double { sampler.currentUp }

    /// Весь трафик за выбранный промежуток — разница итогов ядра на его границах.
    private var windowBytes: (down: Int64, up: Int64) {
        sampler.bytes(in: window.seconds, until: windowEnd)
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
        Task {
            // Ядро выключено — опроса нет, но сэмплы продолжаем писать: график
            // должен идти по времени, а не замирать на последней точке.
            let snapshot = engine.running
                ? await ClashApi.snapshot()
                : (list: [ClashApi.Connection](), totals: ClashApi.Totals())
            let list = snapshot.list
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
                    return now.timeIntervalSince(closed) > 10
                }
                if recentlyClosed.count > 80 {
                    recentlyClosed = Array(recentlyClosed.suffix(80))
                }

                connections = list.count > 400 ? Array(list.prefix(400)) : list
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
            parts.append(folderName(item))
            parts.append(exitName(item))
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

    /// Размер строкой: единицу подбирает общий формат приложения.
    static func size(_ bytes: Int64) -> String {
        Format.size(bytes)
    }

    static func rate(_ value: Double) -> String {
        Format.rate(value)
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
    case insert(RouteInsertPrefill)
    case export(URL)

    var id: String {
        switch self {
        case .detail(let item): return "detail-" + item.id
        case .filter: return "filter"
        case .insert(let prefill): return "insert-" + prefill.id.uuidString
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
    /// Имя папки маршрута и человеческое имя выхода — считает список.
    let folderName: String
    let exitName: String
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

                    Button {
                        let proto = connection.proto.split(separator: "/").first.map(String.init) ?? ""
                        insert(attr: "protocol", value: proto, title: "протокол → правило")
                    } label: {
                        row(title: connection.proto.isEmpty ? "—" : connection.proto,
                            subtitle: "протокол → правило")
                    }
                    .disabled(connection.proto.isEmpty)
                } header: {
                    Text("Перенести в правило")
                } footer: {
                    Text("Нажмите на домен — откроется выбор профиля и папки: значение ляжет в выбранную папку своим атрибутом.")
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
                        Text("Папка")
                        Spacer()
                        Text(folderName)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    HStack {
                        Text("Условие")
                        Spacer()
                        Text(connection.isService ? "замер пинга" : connection.rule)
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
                    if !connection.isService {
                        HStack {
                            Text("Выход")
                            Spacer()
                            Text(exitName)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
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
    /// Накопленный итог ядра на момент сэмпла — по нему считается окно.
    let totalDown: Int64
    let totalUp: Int64
    let byOutbound: [String: TrafficRates]
    let bytesByOutbound: [String: TrafficCounters]
}

/// График за выбранное окно: X — реальное время (четыре деления),
/// Y — максимум, середина и ноль. Входящий — акцентом, исходящий — серым.
struct TrafficGraph: View {
    let points: [(at: Date, down: Double, up: Double)]
    let start: Date
    let end: Date

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                    grid(size: geometry.size)
                    line(incoming: true, peak: peak, size: geometry.size, color: Theme.accent)
                    line(incoming: false, peak: peak, size: geometry.size, color: .gray)
                    axisLabels(size: geometry.size)
                    if display.count < 2 {
                        Text("нет данных за это окно")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: 96)
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    Text(tickLabel(index))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity,
                               alignment: index == 0 ? .leading
                                   : (index == 3 ? .trailing : .center))
                }
            }
        }
    }

    /// Точки для отрисовки: последний сэмпл дотягиваем до «сейчас» его же
    /// значением — график всегда доходит до правого края и плавно уезжает влево.
    private var display: [(at: Date, down: Double, up: Double)] {
        guard let last = points.last else { return points }
        if last.at >= end.addingTimeInterval(-0.5) { return points }
        return points + [(end, last.down, last.up)]
    }

    private var peak: Double {
        let maximum = display.map { max($0.down, $0.up) }.max() ?? 0
        return maximum > 0 ? maximum : 1
    }

    /// Подпись деления по X: слева — всё окно назад, справа — «сейчас».
    private func tickLabel(_ index: Int) -> String {
        if index == 3 { return "сейчас" }
        let span = end.timeIntervalSince(start)
        return agoLabel(end.addingTimeInterval(-span * Double(3 - index) / 3))
    }

    /// Максимум, середина и ноль — по левому краю графика.
    private func axisLabels(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Верх шкалы — максимум за окно, середина — его половина.
            Text(Format.rate(peak))
                .offset(x: 4, y: 2)
            Text(Format.rate(peak / 2))
                .offset(x: 4, y: size.height / 2 - 6)
            Text("0")
                .offset(x: 4, y: size.height - 14)
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }

    /// Три горизонтальные линии — четверть, половина и три четверти.
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

    /// X считается по времени, а линия сглаживается квадратичными кривыми
    /// через середины отрезков — так график не выглядит «пилой».
    private func line(incoming: Bool, peak: Double, size: CGSize, color: Color) -> some View {
        let span = max(end.timeIntervalSince(start), 1)
        let points: [CGPoint] = display.map { point in
            let x = CGFloat(max(min(point.at.timeIntervalSince(start) / span, 1), 0)) * size.width
            let value = incoming ? point.down : point.up
            let ratio = CGFloat(max(min(value / peak, 1), 0))
            let y = size.height - ratio * (size.height - 8) - 4
            return CGPoint(x: x, y: y)
        }
        return Path { path in
            guard let first = points.first, points.count > 1 else { return }
            path.move(to: first)
            for index in 1..<points.count {
                let current = points[index]
                if index == points.count - 1 {
                    path.addLine(to: current)
                } else {
                    let next = points[index + 1]
                    let middle = CGPoint(x: (current.x + next.x) / 2,
                                         y: (current.y + next.y) / 2)
                    path.addQuadCurve(to: middle, control: current)
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }

    /// Не абсолютное время, а «сколько назад»: −2 мин, −30 с.
    private func agoLabel(_ date: Date) -> String {
        let seconds = Int(end.timeIntervalSince(date).rounded())
        if seconds <= 5 { return "сейчас" }
        if seconds < 60 { return "−" + String(seconds) + " с" }
        let minutes = seconds / 60
        if minutes < 60 { return "−" + String(minutes) + " мин" }
        return "−" + String(minutes / 60) + " ч"
    }
}




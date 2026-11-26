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

    /// Что показываем: на паузе — снимок плюс те, кто закрылся в последние пять секунд.
    private var shown: [ClashApi.Connection] {
        guard paused else { return connections }
        var merged = connections
        for item in recentlyClosed where !merged.contains(where: { $0.id == item.id }) {
            merged.append(item)
        }
        return merged
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
                    UIPasteboard.general.string = plainText(visible)
                    notice = "скопировано: \(visible.count) соединений"
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
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                Button {
                    activeSheet = .detail(item)
                } label: {
                    connectionRow(index: index + 1, item: item)
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
            Text("Соединения")
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

    private func connectionRow(index: Int, item: ClashApi.Connection) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text(String(index))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 18)
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text(item.destination)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.duration(item.start))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Text(item.source)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if !item.proto.isEmpty {
                        Text(item.proto)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
                HStack(spacing: 4) {
                    Text(networkText(item))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("↑ " + Self.size(Int64(item.upload)))
                        .font(.caption2)
                    Text("↓ " + Self.size(Int64(item.download)))
                        .font(.caption2)
                }
                .lineLimit(1)
                Text(ruleText(item))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(item.outbound)
                    .font(.caption2)
                    .foregroundColor(Theme.accent)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(Color(uiColor: .tertiaryLabel))
                .padding(.top, 3)
        }
        .padding(.vertical, 3)
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
                for item in connections where !currentIDs.contains(item.id) {
                    if !recentlyClosed.contains(where: { $0.id == item.id }) {
                        recentlyClosed.append(item)
                        closedAt[item.id] = now
                    }
                }
                recentlyClosed.removeAll { item in
                    guard let closed = closedAt[item.id] else { return true }
                    return now.timeIntervalSince(closed) > 5
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
        lines.append("Соединения · \(Self.fileStamp.string(from: Date())) · всего \(list.count)")
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
        guard let start else { return "" }
        let seconds = max(Int(Date().timeIntervalSince(start)), 0)
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

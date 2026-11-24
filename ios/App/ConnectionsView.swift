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
    @State private var selected: ClashApi.Connection?
    @State private var refreshed = Date()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var ruleNames: [String] {
        var names: [String] = []
        for item in connections where !names.contains(item.rule) { names.append(item.rule) }
        return names.sorted()
    }

    private var visible: [ClashApi.Connection] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connections.filter { item in
            if !ruleFilter.isEmpty, item.rule != ruleFilter { return false }
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
        for item in connections { total += Int64(item.upload) }
        return total
    }

    private var totalDown: Int64 {
        var total: Int64 = 0
        for item in connections { total += Int64(item.download) }
        return total
    }

    var body: some View {
        NavigationView {
            List {
                summarySection
                filterSection
                listSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Соединения")
            .onReceive(timer) { _ in refresh() }
            .onAppear { refresh() }
            .sheet(item: $selected) { item in
                ConnectionDetailView(connection: item) { attr, value, title in
                    selected = nil
                    // Даём шторке закрыться, иначе переход не виден.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        router.openRouting(with: RouteInsertPrefill(title: title, attr: attr, value: value))
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
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
                Text(String(connections.count)).foregroundColor(.secondary)
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

    private var filterSection: some View {
        Section {
            TextField("домен, IP или порт", text: $query)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Picker("Сеть", selection: $networkFilter) {
                Text("Все").tag(0)
                Text("tcp").tag(1)
                Text("udp").tag(2)
            }
            .pickerStyle(.segmented)
            Menu {
                Button("Все правила") { ruleFilter = "" }
                ForEach(ruleNames, id: \.self) { name in
                    Button(name) { ruleFilter = name }
                }
            } label: {
                HStack {
                    Text("Правило")
                    Spacer()
                    Text(ruleFilter.isEmpty ? "все" : ruleFilter)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Фильтр")
        } footer: {
            Text(visible.count == connections.count
                 ? "Показаны все соединения"
                 : "Показано \(visible.count) из \(connections.count)")
        }
    }

    private var listSection: some View {
        Section {
            if connections.isEmpty {
                Text(engine.running
                     ? "живых соединений нет"
                     : "ядро выключено — поднимите туннель на вкладке «Серверы»")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                Button {
                    selected = item
                } label: {
                    connectionRow(index: index + 1, item: item)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Соединения")
        }
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

    private func refresh() {
        guard engine.running else {
            connections = []
            return
        }
        Task {
            let list = await ClashApi.connections()
            await MainActor.run {
                connections = list
                refreshed = Date()
                if !ruleFilter.isEmpty, !list.contains(where: { $0.rule == ruleFilter }) {
                    ruleFilter = ""
                }
            }
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
}

/// Подробности соединения: адрес, порт и кнопки «добавить в правило».
struct ConnectionDetailView: View {
    @EnvironmentObject private var rules: RuleStore
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

import SwiftUI

/// Статистика: счётчики, последние пинги, скорость, трафик, правило для домена и живые соединения.
/// Тело разбито на секции: SwiftUI не успевает типизировать один большой `List`.
struct StatsView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var traffic: TrafficMonitor
    @StateObject private var stats = TrafficStatsStore.shared

    @State private var period = 7
    @State private var domain = ""
    @State private var connections: [ClashApi.Connection] = []

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            countersSection
            pingsSection
            speedSection
            trafficSection
            ruleSection
            connectionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in refreshConnections() }
    }

    // MARK: - Данные

    private var checked: [DevEngine.BulkRow] {
        var items: [DevEngine.BulkRow] = []
        for row in engine.bulk where row.done { items.append(row) }
        return items
    }

    private var alive: [DevEngine.BulkRow] {
        var items: [DevEngine.BulkRow] = []
        for row in engine.bulk {
            if row.result?.ok == true { items.append(row) }
        }
        return items
    }

    private var sortedAlive: [DevEngine.BulkRow] {
        var items = alive
        items.sort { left, right in
            let a = left.result?.millis ?? Int.max
            let b = right.result?.millis ?? Int.max
            return a < b
        }
        return items
    }

    private var fastest: DevEngine.BulkRow? {
        var best: DevEngine.BulkRow?
        var bestMillis = Int.max
        for item in alive {
            guard let millis = item.result?.millis else { continue }
            if millis < bestMillis {
                bestMillis = millis
                best = item
            }
        }
        return best
    }

    private var trafficRows: [TrafficStatsStore.Row] {
        stats.summary(days: period)
    }

    private var fastestText: String {
        guard let fastest, let millis = fastest.result?.millis else { return "—" }
        return fastest.name + " · " + String(millis) + " мс"
    }

    // MARK: - Секции

    private var countersSection: some View {
        Section {
            statRow("Серверов в списке", String(store.profiles.count))
            statRow("Проверено", String(checked.count))
            statRow("Отвечает", String(alive.count))
            statRow("Быстрейший", fastestText)
        } header: {
            Text("Счётчики")
        }
    }

    private var pingsSection: some View {
        Section {
            if sortedAlive.isEmpty {
                Text("пока никто не проверен — нажмите пинг в заголовке списка серверов")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(sortedAlive) { item in
                pingRow(item)
            }
        } header: {
            Text("Последние пинги")
        }
    }

    private var speedSection: some View {
        Section {
            SpeedGraph(down: traffic.down, up: traffic.up)
                .frame(height: 110)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            HStack {
                Label(Self.rate(traffic.speedDown), systemImage: "arrow.down")
                    .foregroundColor(.green)
                Spacer()
                Label(Self.rate(traffic.speedUp), systemImage: "arrow.up")
                    .foregroundColor(.orange)
            }
            .font(.footnote.weight(.medium))
        } header: {
            HStack {
                Text("Скорость сейчас")
                Spacer()
                Text(traffic.live ? "live" : "нет данных")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Срез раз в секунду из Clash API живого ядра: последние 60 секунд.")
        }
    }

    private var trafficSection: some View {
        Section {
            Picker("Период", selection: $period) {
                Text("7 дней").tag(7)
                Text("30 дней").tag(30)
            }
            .pickerStyle(.segmented)

            if trafficRows.isEmpty {
                Text("пока нечего показывать: трафик копится, пока приложение подключено")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(trafficRows) { item in
                trafficRow(item)
            }
        } header: {
            Text("Трафик по серверам")
        }
    }

    private var ruleSection: some View {
        Section {
            TextField("например, cdn.example.com", text: $domain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Text(rules.evaluate(domain))
                .font(.footnote)
                .foregroundColor(.secondary)
        } header: {
            Text("По какому правилу пойдёт домен")
        } footer: {
            Text("Проверка идёт по вашим правилам, без запуска ядра.")
        }
    }

    private var connectionsSection: some View {
        Section {
            if connections.isEmpty {
                Text(engine.running
                     ? "живых соединений нет"
                     : "ядро выключено — поднимите туннель, чтобы видеть соединения")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(connections) { connection in
                connectionRow(connection)
            }
        } header: {
            Text("Соединения сейчас")
        } footer: {
            Text("Данные из Clash API: хост, цепочка outbound, сработавшее правило и объём.")
        }
    }

    // MARK: - Строки

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func pingRow(_ item: DevEngine.BulkRow) -> some View {
        HStack {
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text(item.result?.shortSummary ?? "—")
                .font(.caption.weight(.medium))
                .foregroundColor(Theme.pingColor(item.result?.millis))
        }
    }

    private func trafficRow(_ item: TrafficStatsStore.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.profile)
                .font(.subheadline)
                .lineLimit(1)
            Text("↑ " + Self.size(item.up) + " · ↓ " + Self.size(item.down))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func connectionRow(_ connection: ClashApi.Connection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(connection.host)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text("через " + (connection.chain.last ?? "—") + " · правило " + connection.rule)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text("↑ " + Self.size(Int64(connection.upload)) + " · ↓ " + Self.size(Int64(connection.download)))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Обновление соединений

    private func refreshConnections() {
        guard engine.running else {
            connections = []
            return
        }
        Task {
            let list = await ClashApi.connections()
            await MainActor.run { self.connections = list }
        }
    }

    // MARK: - Формат

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        let value = ByteCountFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)), countStyle: .file)
        return value + "/с"
    }
}

/// Мини-график скорости: две линии (входящая и исходящая) по последним 60 срезам.
struct SpeedGraph: View {
    let down: [Double]
    let up: [Double]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                line(values: down,
                     peak: peak,
                     size: geometry.size,
                     color: .green)
                line(values: up,
                     peak: peak,
                     size: geometry.size,
                     color: .orange)
            }
        }
    }

    private var peak: Double {
        let candidates = [(down.max() ?? 0), (up.max() ?? 0), 1]
        return candidates.max() ?? 1
    }

    private func line(values: [Double], peak: Double, size: CGSize, color: Color) -> some View {
        Path { path in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(values.count - 1, 1))
            for index in values.indices {
                let x = CGFloat(index) * step
                let ratio = CGFloat(values[index] / peak)
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
}

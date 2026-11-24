import SwiftUI

/// Статистика подключений: сколько серверов проверено и работает, кто быстрее,
/// какие соединения живут сейчас и по какому правилу ядро их отправило.
struct StatsView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var traffic: TrafficMonitor
    @StateObject private var stats = TrafficStatsStore.shared
    @State private var period = 7

    @State private var connections: [ClashApi.Connection] = []
    @State private var domain = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var trafficRows: [TrafficStatsStore.Row] { stats.summary(days: period) }
    private var checked: [DevEngine.BulkRow] { engine.bulk.filter { $0.done } }
    private var alive: [DevEngine.BulkRow] { engine.bulk.filter { $0.result?.ok == true } }

    private var fastest: DevEngine.BulkRow? {
        alive.filter { $0.result?.millis != nil }.min { ($0.result?.millis ?? Int.max) < ($1.result?.millis ?? Int.max) }
    }

    var body: some View {
        List {
            Section {
                row("Серверов в списке", "\(store.profiles.count)")
                row("Проверено", "\(checked.count)")
                row("Отвечает", "\(alive.count)")
                if let fastest, let millis = fastest.result?.millis {
                    row("Быстрейший", fastest.name + " · " + "\(millis) мс")
                }
            } header: {
                Text("Счётчики")
            }

            Section {
                if alive.isEmpty {
                    Text("пока никто не проверен — нажмите пинг в заголовке списка серверов")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(alive.sorted { ($0.result?.millis ?? Int.max) < ($1.result?.millis ?? Int.max) }) { item in
                    HStack {
                        Text(item.name).font(.subheadline).lineLimit(1)
                        Spacer()
                        Text(item.result?.shortSummary ?? "—")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Theme.pingColor(item.result?.millis))
                    }
                }
            } header: {
                Text("Последние пинги")
            }

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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.profile).font(.subheadline).lineLimit(1)
                        Text("↑ " + Self.size(item.up) + " · ↓ " + Self.size(item.down))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Трафик по серверам")
            }

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
                Text("Это проверка по вашим правилам, без запуска ядра.")
            }

            Section {
                if connections.isEmpty {
                    Text(engine.running
                         ? "живых соединений нет"
                         : "ядро выключено — поднимите туннель, чтобы видеть соединения")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(connections) { connection in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(connection.host).font(.caption.weight(.medium)).lineLimit(1)
                        Text("через " + (connection.chain.last ?? "—") + " · правило " + connection.rule)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text("↑ " + Self.size(connection.upload) + " · ↓ " + Self.size(connection.download))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Соединения сейчас")
            } footer: {
                Text("Данные берём из Clash API ядра: он знает хост, цепочку outbound и сработавшее правило.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(timer) { _ in
            guard engine.running else {
                connections = []
                return
            }
            Task { connections = await ClashApi.connections() }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

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
            let width = geometry.size.width
            let height = geometry.size.height
            let peak = max((down.max() ?? 0), (up.max() ?? 0), 1)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                line(values: down, peak: peak, width: width, height: height, color: .green)
                line(values: up, peak: peak, width: width, height: height, color: .orange)
            }
        }
    }

    private func line(values: [Double], peak: Double, width: CGFloat, height: CGFloat, color: Color) -> some View {
        Path { path in
            guard values.count > 1 else { return }
            let step = width / CGFloat(max(values.count - 1, 1))
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                let y = height - CGFloat(value / peak) * (height - 8) - 4
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

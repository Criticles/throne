import SwiftUI

/// Статистика подключений: сколько серверов проверено и работает, кто быстрее,
/// какие соединения живут сейчас и по какому правилу ядро их отправило.
struct StatsView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var rules: RuleStore

    @State private var connections: [ClashApi.Connection] = []
    @State private var domain = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

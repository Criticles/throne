import SwiftUI

/// Живые соединения: что куда идёт, через какой сервер и по какому правилу.
struct ConnectionsView: View {
    @EnvironmentObject private var engine: DevEngine
    @State private var connections: [ClashApi.Connection] = []
    @State private var refreshed = Date()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
                    HStack {
                        Text("Обновлено")
                        Spacer()
                        Text(Self.time.string(from: refreshed)).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Сейчас")
                }

                Section {
                    if connections.isEmpty {
                        Text(engine.running
                             ? "живых соединений нет"
                             : "ядро выключено — поднимите туннель на вкладке «Серверы»")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(connections) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.host)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("через " + (item.chain.last ?? "—"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text("правило " + item.rule + " · ↑ " + Self.size(Int64(item.upload)) + " · ↓ " + Self.size(Int64(item.download)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Соединения")
                } footer: {
                    Text("Данные из Clash API ядра: хост, цепочка outbound, сработавшее правило и объём.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Соединения")
            .onReceive(timer) { _ in refresh() }
            .onAppear { refresh() }
        }
        .navigationViewStyle(.stack)
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
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

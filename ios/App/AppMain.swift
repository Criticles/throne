import SwiftUI

@main
struct OrbitaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var tunnel = TunnelController()
    @State private var log = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(tunnel.statusText).font(.headline)
                    Spacer()
                    Circle()
                        .fill(tunnel.isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                }

                Text("ядро: \(tunnel.coreVersion)")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button {
                    Task { await tunnel.toggle() }
                } label: {
                    Text(tunnel.isConnected ? "Отключить" : "Подключить")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tunnel.busy)

                Text("Лог расширения")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ScrollView {
                    Text(log.isEmpty ? "пусто" : log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.08))
            }
            .padding()
            .navigationTitle("Orbita P0")
        }
        .onAppear { Task { await tunnel.reload() } }
        .onReceive(timer) { _ in log = TunnelLog.read() }
    }
}

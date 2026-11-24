import SwiftUI

@main
struct ThroneApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Три экрана: серверы, маршрут и настройки. Журнал и статистика живут внутри настроек —
/// так на нижней панели остаётся только то, чем пользуются каждый день.
struct RootView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var engine = DevEngine()
    @StateObject private var prefs = Prefs()
    @StateObject private var rules = RuleStore()

    var body: some View {
        TabView {
            ProfilesView()
                .tabItem { Label("Серверы", systemImage: "square.stack.3d.up.fill") }
            RoutingView()
                .tabItem { Label("Маршрут", systemImage: "arrow.triangle.branch") }
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
        }
        .environmentObject(store)
        .environmentObject(engine)
        .environmentObject(prefs)
        .environmentObject(rules)
        .accentColor(Theme.accent)
    }
}

/// Системный VPN через Network Extension. Открывается из настроек, поэтому своего
/// NavigationView не держит — иначе внутри стека получился бы второй.
struct ContentView: View {
    @StateObject private var tunnel = TunnelController()
    @State private var log = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
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
            }

            Section("Лог расширения") {
                Text(log.isEmpty ? "пусто" : log)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Системный VPN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await tunnel.reload() } }
        .onReceive(timer) { _ in log = TunnelLog.read() }
    }
}

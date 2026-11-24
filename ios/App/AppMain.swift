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
    @StateObject private var traffic = TrafficMonitor()
    @StateObject private var updater = UpdateChecker()
    private let upkeep = Timer.publish(every: 1800, on: .main, in: .common).autoconnect()

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
        .environmentObject(traffic)
        .environmentObject(updater)
        .accentColor(Theme.accent)
        .onOpenURL { url in
            // throne://import?url=<ссылка> — так профиль приходит из QR или другого приложения.
            guard url.scheme?.lowercased() == "throne" else { return }
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let value = components.queryItems?.first(where: { $0.name == "url" })?.value {
                Task { await store.importAny(value) }
            }
        }
        .onReceive(upkeep) { _ in
            Task {
                await store.autoUpdateIfNeeded()
                await rules.autoUpdateIfNeeded()
                await scheduleExpiryAlerts()
            }
        }
        .task {
            // Автообновление подписок и наборов правил: фоновых задач iOS не даёт,
            // поэтому проверяем при запуске — и пока приложение открыто, по таймеру.
            await store.autoUpdateIfNeeded()
            await rules.autoUpdateIfNeeded()
            await updater.check()
            await scheduleExpiryAlerts()
        }
    }
}

extension RootView {
    /// Напоминания о конце подписки: одно уведомление на подписку, за 3 дня.
    private func scheduleExpiryAlerts() async {
        guard prefs.notifyExpiry else { return }
        _ = await SubscriptionAlerts.requestPermission()
        for subscription in store.subscriptions {
            await SubscriptionAlerts.schedule(subscription)
        }
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

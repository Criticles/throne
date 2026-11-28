import Libbox
import NetworkExtension
import SwiftUI

/// Управление VPN-профилем: создаёт конфигурацию провайдера, стартует и останавливает туннель.
@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var statusText = "Не настроено"
    @Published private(set) var isConnected = false
    @Published private(set) var busy = false
    @Published private(set) var coreVersion = "—"

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        coreVersion = LibboxVersion()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        Task { await reload() }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            refreshStatus()
        } catch {
            statusText = "Ошибка загрузки профиля: \(error.localizedDescription)"
        }
    }

    /// `config` — готовый конфиг sing-box. Без него поднимаем P0-заглушку
    /// (tun + direct): это только проверка, что дескриптор utun доходит до ядра.
    func toggle(config: String? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if isConnected || isConnecting {
            // Как в Karing: ручное отключение снимает «по требованию», иначе iOS
            // тут же поднимает туннель обратно и выключить VPN невозможно.
            manager?.isOnDemandEnabled = false
            try? await manager?.saveToPreferences()
            manager?.connection.stopVPNTunnel()
            return
        }
        do {
            let manager = try await prepareManager(config: config)
            try manager.connection.startVPNTunnel()
        } catch {
            let described = Self.describe(error)
            statusText = "Ошибка запуска: \(described)"
            TunnelLog.write("start failed: \(described)")
        }
    }

    /// Домен и код важны: именно они отличают «нет entitlement Network Extension»
    /// от «не зарегистрирован провайдер» и от обычной ошибки конфигурации.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    var isConnecting: Bool {
        manager?.connection.status == .connecting || manager?.connection.status == .reasserting
    }

    private func prepareManager(config: String? = nil) async throws -> NETunnelProviderManager {
        let payload = (config?.isEmpty == false ? config : nil) ?? P0Config.json
        P0Config.prepareInContainer()
        TunnelLog.write("config: " + (config == nil ? "P0-заглушка" : "профиль, \(payload.count) байт"))
        TunnelLog.clear()

        let manager = self.manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Shared.tunnelBundleID
        proto.serverAddress = "127.0.0.1"
        proto.providerConfiguration = [Shared.configKey: payload]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Throne"
        manager.isEnabled = true
        // Always-on: iOS сам поднимает туннель при появлении сети и перезапускает его
        // после падения. Без on-demand VPN остаётся выключенным до ручного включения.
        // `disconnectOnSleep` по умолчанию false, но выставляем явно: иначе iOS
        // может погасить туннель при блокировке экрана.
        proto.disconnectOnSleep = false
        let keep = UserDefaults.standard.object(forKey: "prefs.keepConnected") as? Bool ?? true
        manager.isOnDemandEnabled = keep
        manager.onDemandRules = keep ? [NEOnDemandRuleConnect()] : []
        TunnelLog.write("onDemand: \(keep ? "вкл" : "выкл")")
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            TunnelLog.write("saveToPreferences failed: \(Self.describe(error))")
            throw error
        }
        self.manager = manager
        refreshStatus()
        return manager
    }

    private func refreshStatus() {
        guard let connection = manager?.connection else {
            statusText = "Профиль не создан"
            isConnected = false
            return
        }
        switch connection.status {
        case .invalid: statusText = "Профиль недействителен"
        case .disconnected: statusText = "Отключено"
        case .connecting: statusText = "Подключение…"
        case .connected: statusText = "Подключено"
        case .reasserting: statusText = "Переподключение…"
        case .disconnecting: statusText = "Отключение…"
        @unknown default: statusText = "Неизвестный статус"
        }
        isConnected = connection.status == .connected
    }
}

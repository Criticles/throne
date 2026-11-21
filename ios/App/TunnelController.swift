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

    func toggle() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if isConnected || isConnecting {
            manager?.connection.stopVPNTunnel()
            return
        }
        do {
            let manager = try await prepareManager()
            try manager.connection.startVPNTunnel()
        } catch {
            statusText = "Ошибка запуска: \(error.localizedDescription)"
            TunnelLog.write("start failed: \(error.localizedDescription)")
        }
    }

    var isConnecting: Bool {
        manager?.connection.status == .connecting || manager?.connection.status == .reasserting
    }

    private func prepareManager() async throws -> NETunnelProviderManager {
        P0Config.prepareInContainer()
        TunnelLog.clear()

        let manager = self.manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Shared.tunnelBundleID
        proto.serverAddress = "127.0.0.1"
        proto.providerConfiguration = [Shared.configKey: P0Config.json]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Throne"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
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

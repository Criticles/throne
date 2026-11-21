import Libbox
import NetworkExtension

/// Системный VPN. Вся работа с ядром — здесь: setup libbox, command server, запуск сервиса.
/// Настройки туннеля (адреса, маршруты, DNS) собирает PlatformInterface по запросу самого ядра.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var platform: PlatformInterface?
    private var commandServer: LibboxCommandServer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        TunnelLog.write("startTunnel: begin")
        do {
            try setupCore()
            let config = try resolveConfig(options: options)
            try startService(config: config)
            TunnelLog.write("startTunnel: service started, libbox \(LibboxVersion())")
            completionHandler(nil)
        } catch {
            TunnelLog.write("startTunnel: failed — \(error.localizedDescription)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        TunnelLog.write("stopTunnel: reason \(reason.rawValue)")
        commandServer?.close()
        commandServer = nil
        platform = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let request = String(data: messageData, encoding: .utf8) ?? ""
        if request == "log" {
            completionHandler?(Data(TunnelLog.read().utf8))
        } else if request == "version" {
            completionHandler?(Data(LibboxVersion().utf8))
        } else {
            completionHandler?(nil)
        }
    }

    // MARK: - Ядро

    private func setupCore() throws {
        let container = Shared.containerURL ?? FileManager.default.temporaryDirectory
        let base = container.appendingPathComponent("libbox", isDirectory: true)
        let working = base.appendingPathComponent("working", isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("libbox-temp", isDirectory: true)

        // 45 МБ и GC 10% на iOS — ровно то, что делает сам sing-box под Network Extension.
        LibboxSetMemoryLimit(true)

        let platform = PlatformInterface(provider: self)
        self.platform = platform

        // Через LibboxBoot: control-сокет libbox переведён на loopback-TCP,
        // иначе unix-путь упирается в лимит sun_path.
        commandServer = try LibboxBoot.start(base: base, working: working, temp: temp,
                                             debug: true, platform: platform)
        TunnelLog.write("setupCore: command server started")
    }

    private func resolveConfig(options: [String: NSObject]?) throws -> String {
        if let inline = options?[Shared.configKey] as? String, !inline.isEmpty {
            TunnelLog.write("config: из options")
            return inline
        }
        if let stored = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?[Shared.configKey] as? String, !stored.isEmpty {
            TunnelLog.write("config: из providerConfiguration")
            return stored
        }
        if let fromDisk = P0Config.loadFromContainer(), !fromDisk.isEmpty {
            TunnelLog.write("config: из App Group")
            return fromDisk
        }
        TunnelLog.write("config: не найден, беру встроенный P0")
        P0Config.prepareInContainer()
        return P0Config.json
    }

    private func startService(config: String) throws {
        guard let commandServer else {
            throw NSError(
                domain: "com.criticles.throne.tunnel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "command server не создан"]
            )
        }
        try commandServer.startOrReloadService(config, options: LibboxOverrideOptions())
        TunnelLog.write("startService: конфиг принят (\(config.count) символов)")
    }
}

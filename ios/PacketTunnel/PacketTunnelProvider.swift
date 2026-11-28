import Libbox
import NetworkExtension

/// Системный VPN. Вся работа с ядром — здесь: setup libbox, command server, запуск сервиса.
/// Настройки туннеля (адреса, маршруты, DNS) собирает PlatformInterface по запросу самого ядра.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var platform: PlatformInterface?
    private var commandServer: LibboxCommandServer?
    /// Пульс расширения: по нему видно, когда туннель «уснул» и убила ли его система.
    private var heartbeat: DispatchSourceTimer?
    private var startedAt = Date()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        TunnelLog.write("startTunnel: begin")
        do {
            try setupCore()
            let config = try resolveConfig(options: options)
            try startService(config: config)
            startedAt = Date()
            startHeartbeat()
            TunnelLog.write("startTunnel: service started, libbox \(LibboxVersion()), память \(Self.footprintMB) МБ")
            completionHandler(nil)
        } catch {
            TunnelLog.write("startTunnel: failed — \(error.localizedDescription)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        heartbeat?.cancel()
        heartbeat = nil
        let lived = Int(Date().timeIntervalSince(startedAt))
        TunnelLog.write("stopTunnel: reason \(reason.rawValue), жил \(lived) с, память \(Self.footprintMB) МБ")
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

    // MARK: - Пульс и память

    /// Раз в минуту пишем в общий лог, что расширение живо и сколько занимает.
    /// Если запись оборвалась, а stopTunnel не отметился — значит расширение убила система.
    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "throne.heartbeat"))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            let lived = Int(Date().timeIntervalSince(self.startedAt))
            TunnelLog.write("alive: \(lived) с, память \(Self.footprintMB) МБ")
        }
        timer.resume()
        heartbeat = timer
    }

    /// phys_footprint — то, что реально считает jetsam. Лимит расширения ~50 МБ.
    private static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    // MARK: - Ядро

    private func setupCore() throws {
        let container = Shared.containerURL ?? FileManager.default.temporaryDirectory
        let base = container.appendingPathComponent("libbox", isDirectory: true)
        let working = base.appendingPathComponent("working", isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("libbox-temp", isDirectory: true)

        // Лимит памяти расширения раньше ставился через LibboxSetMemoryLimit(true);
        // в новом API этой функции нет — при необходимости передаётся в SetupOptions.

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

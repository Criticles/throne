import Foundation
import TurnableCore

/// Обёртка над Go-биндингом Turnable (TurnableCore.xcframework).
///
/// Turnable — транспорт, а не VPN: клиент поднимает локальный UDP-порт и гонит
/// пакеты через VK TURN/SFU. Для WireTurn-профиля sing-box смотрит на этот порт
/// wireguard-эндпоинтом, поэтому порядок строгий: сначала Turnable, потом ядро.
final class TurnableEngine: NSObject, TurnablecoreLogSink {
    private let onLog: (String) -> Void
    private(set) var running = false
    private(set) var listenAddress = ""

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        super.init()
    }

    /// Готовит каталог и неинтерактивный режим. Вызывать один раз до старта.
    static func prepare(basePath: URL) throws {
        try TurnablecoreSetup(basePath.path)
        TunnelLog.write("turnable: \(TurnablecoreVersion())")
    }

    static var isPrepared: Bool { true }

    /// Поднимает транспорт. configJSON — `kernelConfig.config` из wireturn-профиля.
    func start(configJSON: String, listen: String) throws {
        if running {
            stop()
        }
        TurnablecoreSetLogSink(self)
        do {
            try TurnablecoreStart(configJSON, listen)
        } catch {
            TurnablecoreSetLogSink(nil)
            let ns = error as NSError
            throw NSError(domain: "throne.turnable", code: ns.code,
                          userInfo: [NSLocalizedDescriptionKey: "Turnable: \(ns.localizedDescription)"])
        }
        running = true
        listenAddress = TurnablecoreListenAddress()
        onLog("turnable: запущен, слушает \(listenAddress)")
    }

    func stop() {
        guard running else { return }
        do {
            try TurnablecoreStop()
            onLog("turnable: остановлен")
        } catch {
            onLog("turnable: ошибка остановки — \(error.localizedDescription)")
        }
        running = false
        listenAddress = ""
        TurnablecoreSetLogSink(nil)
    }

    // MARK: - TurnablecoreLogSink

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        onLog("turnable: \(message)")
    }
}

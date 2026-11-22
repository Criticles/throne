import Foundation
import Libbox

/// Обёртка над Go-биндингом Turnable (TurnableCore.xcframework).
///
/// Turnable — транспорт, а не VPN: клиент поднимает локальный UDP-порт и гонит
/// пакеты через VK TURN/SFU. Для WireTurn-профиля sing-box смотрит на этот порт
/// wireguard-эндпоинтом, поэтому порядок строгий: сначала Turnable, потом ядро.
///
/// gomobile импортировал функции как `(…, NSErrorPointer) -> Bool`, поэтому ошибки
/// забираем через указатель, а не через `throws`.
final class TurnableEngine: NSObject, LibboxLogSinkProtocol {
    private let onLog: (String) -> Void
    private(set) var running = false
    private(set) var listenAddress = ""

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        super.init()
    }

    /// Каталог и неинтерактивный режим (капчи без браузера). Вызывать до старта.
    static func prepare(basePath: URL) throws {
        var error: NSError?
        let ok = LibboxTurnableSetup(basePath.path, &error)
        try raise(ok, error)
        TunnelLog.write("turnable: биндинг в ядре \(LibboxVersion())")
    }

    /// Поднимает транспорт. configJSON — `kernelConfig.config` из wireturn-профиля.
    func start(configJSON: String, listen: String) throws {
        if running { stop() }
        LibboxTurnableSetLogSink(self)

        var error: NSError?
        let ok = LibboxTurnableStart(configJSON, listen, &error)
        if !ok {
            LibboxTurnableSetLogSink(nil)
            let ns = error ?? NSError(domain: "throne.turnable", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "неизвестная ошибка"])
            throw NSError(domain: "throne.turnable", code: ns.code,
                          userInfo: [NSLocalizedDescriptionKey: "Turnable: \(ns.localizedDescription)"])
        }
        running = true
        listenAddress = LibboxTurnableListenAddress()
        onLog("turnable: запущен, слушает \(listenAddress)")
    }

    func stop() {
        guard running else { return }
        var error: NSError?
        let ok = LibboxTurnableStop(&error)
        if ok {
            onLog("turnable: остановлен")
        } else {
            onLog("turnable: ошибка остановки — \(error?.localizedDescription ?? "?")")
        }
        running = false
        listenAddress = ""
        LibboxTurnableSetLogSink(nil)
    }

    private static func raise(_ ok: Bool, _ error: NSError?) throws {
        guard !ok else { return }
        let ns = error ?? NSError(domain: "throne.turnable", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "неизвестная ошибка"])
        throw NSError(domain: "throne.turnable", code: ns.code,
                      userInfo: [NSLocalizedDescriptionKey: "Turnable: \(ns.localizedDescription)"])
    }

    // MARK: - LibboxLogSinkProtocol

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        onLog("turnable: \(message)")
    }
}

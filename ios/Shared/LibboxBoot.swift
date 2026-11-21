import Foundation
import Libbox

/// Запуск command server из libbox с обходом лимита длины unix-сокета.
///
/// По умолчанию libbox слушает `unix:<basePath>/command.sock`. Путь unix-сокета ограничен
/// примерно 104 байтами (`sun_path`), а внутри вложенных контейнеров — например, в LiveContainer —
/// реальный путь до `Library/Application Support/libbox/` уже длиннее. `bind` возвращает
/// `invalid argument`, и ядро не стартует вовсе.
///
/// Поэтому просим у libbox TCP-порт на loopback: `commandServerListenPort != 0` переключает
/// `CommandServer.Start()` на `127.0.0.1:<port>`. Порты перебираем, чтобы не упасть на занятом.
enum LibboxBoot {
    /// Кандидаты для control-порта (loopback, только внутри процесса).
    static let candidatePorts: [Int32] = [9101, 9102, 9103, 9104]

    struct BootError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func start(
        base: URL,
        working: URL,
        temp: URL,
        debug: Bool,
        platform: LibboxPlatformInterfaceProtocol & LibboxCommandServerHandlerProtocol
    ) throws -> LibboxCommandServer {
        var lastError: Error?
        for port in candidatePorts {
            do {
                try setup(base: base, working: working, temp: temp, debug: debug, port: port)
                var serverError: NSError?
                guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
                    throw serverError ?? BootError(message: "не удалось создать command server")
                }
                try server.start()
                return server
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? BootError(message: "не удалось запустить command server")
    }

    private static func setup(base: URL, working: URL, temp: URL, debug: Bool, port: Int32) throws {
        for url in [base, working, temp] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let options = LibboxSetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.logMaxLines = 2000
        options.debug = debug
        options.commandServerSecret = ""
        options.commandServerListenPort = port

        var setupError: NSError?
        _ = LibboxSetup(options, &setupError)
        if let setupError {
            throw setupError
        }
    }
}

import Foundation
import Libbox

/// Ядро sing-box внутри процесса приложения: локальный SOCKS на 127.0.0.1:7891,
/// наружу — через VLESS-профиль. Без Network Extension, без entitlement'ов.
@MainActor
final class DevEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var log: String = ""
    @Published private(set) var lastError: String?

    private var server: LibboxCommandServer?
    private var platform: DevPlatform?

    var socksAddress: String { "127.0.0.1:\(DevConfig.listenPort)" }

    func start(link: VLESSLink) {
        stop()
        do {
            let config = try DevConfig.build(link: link)
            try boot()
            try server?.startOrReloadService(config, options: LibboxOverrideOptions())
            running = true
            lastError = nil
            append("старт: \(link.name) → \(link.host):\(link.port), локально \(socksAddress)")
        } catch {
            let described = Self.describe(error)
            lastError = described
            append("ошибка старта: \(described)")
            stop()
            running = false
        }
    }

    func stop() {
        server?.close()
        server = nil
        platform = nil
        running = false
    }

    func clearLog() {
        log = ""
    }

    /// Ошибки уровня UI (например, не разобралась share-ссылка).
    func report(_ message: String) {
        lastError = message
        append(message)
    }

    private func boot() throws {
        let container = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        let base = container.appendingPathComponent("libbox", isDirectory: true)
        let working = base.appendingPathComponent("working", isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("libbox-temp", isDirectory: true)
        for url in [base, working, temp] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let options = LibboxSetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.logMaxLines = 2000
        options.debug = true
        options.commandServerSecret = ""

        var setupError: NSError?
        _ = LibboxSetup(options, &setupError)
        if let setupError {
            throw setupError
        }
        // В приложении лимит памяти расширения не нужен — ведём себя как обычный клиент.
        LibboxSetMemoryLimit(false)

        let platform = DevPlatform { [weak self] text in
            Task { @MainActor in self?.append(text) }
        }
        self.platform = platform

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
            throw serverError ?? NSError(domain: "com.criticles.throne.dev", code: 10,
                                         userInfo: [NSLocalizedDescriptionKey: "не удалось создать command server"])
        }
        try server.start()
        self.server = server
        append("ядро: \(LibboxVersion())")
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log += "[\(stamp)] \(line)\n"
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }
}

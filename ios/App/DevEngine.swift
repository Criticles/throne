import Foundation
import Libbox

/// Ядро sing-box внутри процесса приложения: локальный SOCKS на 127.0.0.1:7891,
/// наружу — через VLESS-профиль. Без Network Extension, без entitlement'ов.
@MainActor
final class DevEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var log: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var activeName: String?

    private var server: LibboxCommandServer?
    private var platform: DevPlatform?

    var socksAddress: String { "127.0.0.1:\(ConfigBuilder.listenPort)" }

    func start(profile: Profile) {
        stop()
        do {
            let config = try ConfigBuilder.build(profile: profile)
            try boot()
            try server?.startOrReloadService(config, options: LibboxOverrideOptions())
            running = true
            lastError = nil
            activeName = profile.name
            append("старт: \(profile.name) [\(profile.kind.title)] → локально \(socksAddress)")
            if let note = profile.note {
                append("внимание: \(note)")
            }
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
        activeName = nil
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

        // В приложении лимит памяти расширения не нужен — ведём себя как обычный клиент.
        LibboxSetMemoryLimit(false)

        let platform = DevPlatform { [weak self] text in
            Task { @MainActor in self?.append(text) }
        }
        self.platform = platform

        // Через LibboxBoot: внутри LiveContainer unix-сокет libbox не влезает в лимит пути.
        server = try LibboxBoot.start(base: base, working: working, temp: temp,
                                      debug: true, platform: platform)
        append("ядро: \(LibboxVersion())")
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        log += "[\(stamp)] \(Self.stripANSI(line))\n"
    }

    /// sing-box пишет логи с ANSI-последовательностями — в Text их видно как `[36mINFO[0m`.
    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m",
                                  with: "",
                                  options: .regularExpression)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }
}

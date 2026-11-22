import Darwin
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
    private lazy var turnable = TurnableEngine { [weak self] line in
        Task { @MainActor in self?.append(line) }
    }

    /// Транспорт Turnable для WireTurn-профилей: sing-box ждёт его на 127.0.0.1:9000.
    static let turnablePort = 9000

    var socksAddress: String { "127.0.0.1:\(ConfigBuilder.listenPort)" }

    func start(profile: Profile) {
        stop()
        do {
            let config = try ConfigBuilder.build(profile: profile)

            // WireTurn: сначала транспорт, иначе wireguard-эндпоинту некуда стучаться.
            if profile.kind == .wireturn {
                let kernelJSON = try Self.kernelConfigJSON(from: profile.payload)
                try turnable.start(configJSON: kernelJSON,
                                   listen: "127.0.0.1:\(Self.turnablePort)")
                append("wireturn: транспорт поднят на 127.0.0.1:\(Self.turnablePort)")
            }

            try boot()
            guard let server else {
                throw NSError(domain: "orbita.engine", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "command server не создан"])
            }
            // checkConfig из API ядра убран: конфиг проверяется при старте сервиса,
            // и ошибка парсинга всё равно придёт от startOrReloadService.
            try server.startOrReloadService(config, options: LibboxOverrideOptions())
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
        turnable.stop()
        guard let server else {
            running = false
            activeName = nil
            return
        }
        // close() закрывает только command-сервер; сам sing-box продолжает работать и держать
        // порт 7891 — поэтому сначала гасим сервис, иначе следующая смена сервера падает.
        do {
            _ = try server.closeService()
        } catch {
            append("стоп сервиса: \(Self.describe(error))")
        }
        server.close()
        self.server = nil
        self.platform = nil
        running = false
        activeName = nil
        append("остановлено")
    }

    /// Слушает ли ядро локальный порт. Если нет — «bad URL» и ошибки прокси
    /// относятся к неудачному старту ядра, а не к серверу.
    func isListening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(ConfigBuilder.listenPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func clearLog() {
        log = ""
    }

    /// Ошибки уровня UI (например, не разобралась share-ссылка).
    func report(_ message: String) {
        lastError = message
        append(message)
    }

    /// Достаёт из payload wireturn-профиля вложенный конфиг клиента Turnable.
    private static func kernelConfigJSON(from payload: String) throws -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let kernel = root["kernel"] as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: kernel, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8)
        else {
            throw NSError(domain: "orbita.turnable", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "в wireturn-профиле нет kernel-конфига"])
        }
        return text
    }

    private func boot() throws {
        let container = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        let base = container.appendingPathComponent("libbox", isDirectory: true)
        let working = base.appendingPathComponent("working", isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("libbox-temp", isDirectory: true)

        // Транспорт Turnable готовим один раз: каталог + неинтерактивный режим (капчи без браузера).
        try? TurnableEngine.prepare(basePath: base)

        // В приложении лимит памяти расширения не нужен: LibboxSetMemoryLimit из API убран,
        // а SetupOptions памяти не касается — ведём себя как обычный клиент.

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

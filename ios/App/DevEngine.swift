import Darwin
import Foundation
import Libbox

/// Ядро sing-box внутри процесса приложения: локальный SOCKS на 127.0.0.1:7891,
/// наружу — через VLESS-профиль. Без Network Extension, без entitlement'ов.
@MainActor
final class DevEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    @Published private(set) var activeName: String?
    /// MTU для WireTurn: поверх TURN/SRTP панельные 1280 фрагментируются.
    @Published var wireturnMTU: Int = 1200
    /// Поднят только транспорт Turnable (профиль без wgConfig): туннеля нет, проверяем VK/SRTP.
    @Published private(set) var transportOnly = false

    private var server: LibboxCommandServer?
    private var platform: DevPlatform?
    private lazy var turnable = TurnableEngine { [weak self] line in
        Task { @MainActor in self?.append(line) }
    }

    /// Транспорт Turnable для WireTurn-профилей: sing-box ждёт его на 127.0.0.1:9000.
    static let turnablePort = 9000

    var socksAddress: String { "127.0.0.1:\(ConfigBuilder.listenPort)" }

    /// Поднят ли транспорт Turnable (нужно для отчёта по профилям без wgConfig).
    var isTransportRunning: Bool { turnable.running }

    func start(profile: Profile) {
        stop()
        // Профиль Turnable из панели — это только транспорт: gateway, call_id, pub_key.
        // Ключей WireGuard в нём нет, поэтому запускаем Turnable и честно говорим, что туннеля не будет.
        if profile.kind == .turnable {
            startTransportOnly(profile)
            return
        }
        do {
            if profile.kind == .wireturn {
                ConfigBuilder.wireturnMTU = wireturnMTU
                append("wireturn: MTU \(wireturnMTU)")
            } else {
                ConfigBuilder.wireturnMTU = nil
            }
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

    /// Проверка одного Turnable: авторизация VK, капча, SRTP-хендшейк с гейтвеем.
    private func startTransportOnly(_ profile: Profile) {
        do {
            try turnable.start(configJSON: profile.payload,
                               listen: "127.0.0.1:\(Self.turnablePort)")
            transportOnly = true
            activeName = profile.name
            running = false
            lastError = nil
            append("turnable: транспорт поднят на 127.0.0.1:\(Self.turnablePort)")
            append("turnable: в профиле нет wgConfig — туннеля не будет, это проверка транспорта (VK авторизация, SRTP)")
        } catch {
            let described = Self.describe(error)
            lastError = described
            append("ошибка транспорта Turnable: \(described)")
            stop()
        }
    }

    func stop() {
        transportOnly = false
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
        LogStore.shared.clear()
    }

    /// Ошибки уровня UI (например, не разобралась share-ссылка).
    func report(_ message: String) {
        lastError = message
        append(message)
    }

    // MARK: - Проверка всех серверов

    struct BulkRow: Identifiable {
        let id: UUID
        let name: String
        let badge: String
        var result: ProbeResult?
        var note: String?
        var done = false
    }

    @Published private(set) var bulk: [BulkRow] = []
    @Published private(set) var bulkRunning = false

    /// Проверяет все профили подряд: старт → локальный порт → внешний IP и страна → стоп.
    /// Turnable-профили пропускаются сразу: в них нет ключей, туннель собрать не из чего.
    func checkAll(profiles: [Profile]) async {
        guard !bulkRunning, !profiles.isEmpty else { return }
        bulkRunning = true
        bulk = profiles.map { BulkRow(id: $0.id, name: $0.name, badge: $0.badge ?? $0.kind.title) }
        var wireturnChecked = 0
        for (index, profile) in profiles.enumerated() {
            append("проверка: \(profile.name) [\(profile.kind.title)]")
            // VK ограничивает частоту капч (ERROR_LIMIT), поэтому в серии проверяем только первый
            // WireTurn: иначе вторая-третья авторизации упираются в лимит и «не работают» ложно.
            if profile.kind == .wireturn {
                if wireturnChecked >= 1 {
                    bulk[index].note = "в серии пропущен: у VK-капчи лимит на подряд идущие авторизации"
                    bulk[index].done = true
                    append("пропуск: \(profile.name) — лимит капчи VK на серию")
                    continue
                }
                wireturnChecked += 1
            }

            if profile.kind == .turnable {
                // Транспорт проверяется отдельно: VK-авторизация, капча, SRTP-сессия с гейтвеем.
                start(profile: profile)
                // Хендшейк занимает секунды, поэтому даём транспорту время, а не гасим сразу.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let transportUp = isTransportRunning
                bulk[index].note = transportUp
                    ? "транспорт поднят (VK/SRTP), ключей WireGuard нет — туннеля не будет"
                    : (lastError ?? "транспорт не поднялся")
                bulk[index].done = true
                stop()
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            start(profile: profile)
            let listening = await waitListening()
            if !listening {
                bulk[index].note = lastError ?? "ядро не слушает \(socksAddress)"
                bulk[index].result = ProbeResult(ok: false, error: lastError)
                bulk[index].done = true
                stop()
                continue
            }
            // WireTurn поднимает VK-сессию дольше остальных (авторизация, капча, SRTP):
            // опрашиваем до 30 с, остальные — до 8 с.
            let deadline = Date().addingTimeInterval(profile.kind == .wireturn ? 30 : 8)
            var result = await Probe.viaProxy(port: ConfigBuilder.listenPort)
            while !result.ok, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                result = await Probe.viaProxy(port: ConfigBuilder.listenPort)
            }
            bulk[index].result = result
            bulk[index].done = true
            append("итог: \(profile.name) → \(result.summary)")
            stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        bulkRunning = false
        append("проверка всех серверов завершена")
    }

    /// Ждём, пока ядро откроет локальный порт (до 10 с), не блокируя интерфейс.
    private func waitListening() async -> Bool {
        for _ in 0..<20 {
            if running, isListening() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
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
        LogStore.shared.append(Self.stripANSI(line))
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

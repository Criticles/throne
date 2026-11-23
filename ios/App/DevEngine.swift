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

    /// Локальный прокси активного ядра: sing-box — 7891, Xray — 7892.
    @Published private(set) var proxyPort: Int = ConfigBuilder.listenPort

    var socksAddress: String { "127.0.0.1:\(ConfigBuilder.listenPort)" }

    /// Поднят ли транспорт Turnable (нужно для отчёта по профилям без wgConfig).
    var isTransportRunning: Bool { turnable.running }

    /// Нужен ли транспорту Turnable: WireTurn всегда, Turnable — только если есть ключи WG.
    static func needsTransport(_ profile: Profile) -> Bool {
        switch profile.kind {
        case .wireturn: return true
        case .turnable: return ConfigBuilder.hasWireGuard(profile.payload)
        default: return false
        }
    }

    func start(profile: Profile) {
        stop()
        // Профиль VLESS + XHTTP: sing-box такой транспорт не умеет, поднимаем Xray.
        if profile.kind == .xray {
            startXray(profile)
            return
        }
        // Профиль Turnable без ключей WireGuard — это только транспорт: запускаем Turnable
        // и честно говорим, что туннеля не будет. Если ключи подмешаны — идём общим путём.
        if profile.kind == .turnable && !ConfigBuilder.hasWireGuard(profile.payload) {
            startTransportOnly(profile)
            return
        }
        do {
            if Self.needsTransport(profile) {
                ConfigBuilder.wireturnMTU = wireturnMTU
                append("транспорт: MTU \(wireturnMTU)")
            } else {
                ConfigBuilder.wireturnMTU = nil
            }
            let config = try ConfigBuilder.build(profile: profile)

            // WireTurn и Turnable-с-ключами: сначала транспорт, иначе wireguard-эндпоинту некуда стучаться.
            if Self.needsTransport(profile) {
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

    /// Запуск Xray (VLESS + XHTTP): свой socks-инбаунд на 127.0.0.1:7892.
    private func startXray(_ profile: Profile) {
        do {
            guard let link = try? VLESSLink.parse(profile.payload) else {
                throw NSError(domain: "throne.xray", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "не разобрать vless-ссылку для Xray"])
            }
            let object = XrayConfig.build(link: link)
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8)
            else { throw NSError(domain: "throne.xray", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "не собрать JSON для Xray"]) }

            var error: NSError?
            let ok = LibboxXrayStart(json, &error)
            guard ok else {
                let ns = error ?? NSError(domain: "throne.xray", code: -3,
                                          userInfo: [NSLocalizedDescriptionKey: "неизвестная ошибка"])
                throw NSError(domain: "throne.xray", code: ns.code,
                              userInfo: [NSLocalizedDescriptionKey: "Xray: \(ns.localizedDescription)"])
            }
            proxyPort = XrayConfig.socksPort
            running = true
            lastError = nil
            activeName = profile.name
            append("xray: запущен, socks 127.0.0.1:\(XrayConfig.socksPort)")
            append("старт: \(profile.name) [\(profile.kind.title)] → локально 127.0.0.1:\(XrayConfig.socksPort)")
        } catch {
            let described = Self.describe(error)
            lastError = described
            append("ошибка старта Xray: \(described)")
            stop()
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
            append("turnable: транспорт работает — VK авторизация и SRTP-сессия подняты")
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
        if LibboxXrayIsRunning() {
            var error: NSError?
            _ = LibboxXrayStop(&error)
            append("xray: остановлен")
        }
        proxyPort = ConfigBuilder.listenPort
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
        address.sin_port = UInt16(proxyPort).bigEndian
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
            if Self.needsTransport(profile) {
                if wireturnChecked >= 8 {
                    bulk[index].note = "в серии пропущен: проверяем не больше 8 VK-авторизаций подряд"
                    bulk[index].done = true
                    append("пропуск: \(profile.name) — лимит капчи VK на серию")
                    continue
                }
                wireturnChecked += 1
            }

            if profile.kind == .turnable && !ConfigBuilder.hasWireGuard(profile.payload) {
                // Транспорт проверяется отдельно: VK-авторизация, капча, SRTP-сессия с гейтвеем.
                start(profile: profile)
                // Хендшейк занимает секунды, поэтому даём транспорту время, а не гасим сразу.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let transportUp = isTransportRunning
                bulk[index].note = transportUp
                    ? "транспорт поднят (VK авторизация, SRTP)"
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
            // держим окно до 40 с, остальным хватает 12 с.
            let deadline = Date().addingTimeInterval(Self.needsTransport(profile) ? 40 : 12)
            // Мёртвый профиль (WARP из панели: хендшейк не отвечает) иначе держит очередь
            // десятками секунд — внутри пробы три резервных сервиса по 10–20 с.
            var result = await Probe.timed(port: proxyPort, timeout: Self.needsTransport(profile) ? 20 : 12)
                ?? ProbeResult(ok: false, error: "таймаут проверки")
            while !result.ok, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                result = await Probe.timed(port: proxyPort, timeout: 10) ?? result
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

    /// Проверка одного профиля из списка: старт → IP/страна/пинг → стоп.
    /// Результат кладём в тот же массив, что и «Проверить все», чтобы строка списка
    /// показывала свежие цифры, не сбрасывая остальные.
    func check(profile: Profile) async {
        guard !bulkRunning else { return }
        bulkRunning = true
        let row = BulkRow(id: profile.id, name: profile.name, badge: profile.badge ?? profile.kind.title)
        if let existing = bulk.firstIndex(where: { $0.id == profile.id }) {
            bulk[existing] = row
        } else {
            bulk.append(row)
        }
        guard let index = bulk.firstIndex(where: { $0.id == profile.id }) else {
            bulkRunning = false
            return
        }
        append("проверка: \(profile.name) [\(profile.kind.title)]")
        start(profile: profile)
        if await waitListening() {
            let timeout: Double = Self.needsTransport(profile) ? 20 : 12
            let result = await Probe.timed(port: proxyPort, timeout: timeout)
                ?? ProbeResult(ok: false, error: "таймаут проверки")
            bulk[index].result = result
            append("итог: \(profile.name) → \(result.summary)")
        } else {
            let result = ProbeResult(ok: false, error: lastError ?? "ядро не слушает \(socksAddress)")
            bulk[index].result = result
            append("итог: \(profile.name) → \(result.summary)")
        }
        bulk[index].done = true
        stop()
        bulkRunning = false
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

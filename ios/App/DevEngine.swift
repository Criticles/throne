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
    /// Теги outbound'ов живого конфига: сервер → имя в ядре (для Clash API).
    private var liveTags: [UUID: String] = [:]
    /// Активный профиль: по нему восстанавливаем `final` после перезапуска конфига.
    private(set) var activeProfileID: UUID?
    private lazy var turnable = TurnableEngine { [weak self] line in
        Task { @MainActor in self?.append(line) }
    }

    /// Транспорт Turnable для WireTurn-профилей: sing-box ждёт его на 127.0.0.1:9000.
    static let turnablePort = 9000

    /// Результат замера скорости и профиль, на котором он идёт.
    struct SpeedResult {
        var mbps: Double
        var bytes: Int64
        var seconds: Double
    }
    @Published private(set) var speed: [UUID: SpeedResult] = [:]
    @Published private(set) var speedRunning: UUID?

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

    /// Профили, которые sing-box умеет держать в одном конфиге.
    static let singboxKinds: Set<ProfileKind> = [.vless, .hysteria2, .mieru, .wireguard]

    /// Запуск профиля. `pool` — остальные серверы: они добавляются в тот же конфиг,
    /// чтобы пинги не требовали перезапуска ядра.
    func start(profile: Profile, pool: [Profile] = []) {
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
            // Всё, что ядро умеет держать вместе, кладём в один конфиг: final = выбранный сервер.
            let candidates = pool.filter { Self.singboxKinds.contains($0.kind) }
            let config: String
            if !Self.needsTransport(profile), candidates.count > 1 {
                let built = try ConfigBuilder.buildLive(profiles: candidates, selected: profile)
                config = built.json
                liveTags = built.tags
                append("ядро: \(candidates.count) серверов в одном конфиге, активен \(profile.name)")
            } else {
                config = try ConfigBuilder.build(profile: profile)
                liveTags = [:]
            }

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
            activeProfileID = profile.id
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
            activeProfileID = profile.id
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
        activeProfileID = nil
        liveTags = [:]
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

    /// Профили, задержку которых можно спросить у Clash API прямо в живом конфиге.
    /// WireGuard — это `endpoints`, Clash API их не видит; Xray и WireTurn — другое ядро/транспорт.
    static let parallelKinds: Set<ProfileKind> = [.vless, .hysteria2, .mieru]

    /// Проверка всех серверов: сначала параллельно в уже поднятом ядре, потом WireGuard и Xray
    /// по очереди, и в самом конце WireTurn — он долгий (VK-авторизация, капча, SRTP).
    func checkAll(profiles: [Profile]) async {
        guard !bulkRunning, !profiles.isEmpty else { return }
        bulkRunning = true
        defer { bulkRunning = false }
        bulk = profiles.map { BulkRow(id: $0.id, name: $0.name, badge: $0.badge ?? $0.kind.title) }

        let rest = await measure(profiles)
        let plain = rest.filter { !Self.needsTransport($0) && $0.kind != .xray }
        let xray = rest.filter { $0.kind == .xray }
        let turnable = rest.filter { Self.needsTransport($0) }

        await checkSequential(plain)
        await checkSequential(xray)
        await checkSequential(turnable, limitTransport: true)
        append("проверка всех серверов завершена")
    }

    /// Параллельный замер. Если ядро уже держит все серверы в живом конфиге — просто
    /// спрашиваем Clash API, ничего не перезапуская и не разрывая соединение.
    /// Возвращает профили, которые так проверить нельзя.
    private func measure(_ profiles: [Profile]) async -> [Profile] {
        let targets = profiles.filter { Self.parallelKinds.contains($0.kind) }
        let rest = profiles.filter { !Self.parallelKinds.contains($0.kind) }
        guard !targets.isEmpty else { return rest }

        var needPool = !running
        if !needPool {
            for profile in targets where liveTags[profile.id] == nil {
                needPool = true
                break
            }
        }
        if needPool {
            let pool = profiles.filter { Self.singboxKinds.contains($0.kind) }
            guard let anchor = pool.first(where: { $0.id == activeProfileID }) ?? pool.first else {
                return profiles
            }
            start(profile: anchor, pool: pool)
            guard running else { return profiles }
        }

        for _ in 0..<10 {
            if await ClashApi.version() != nil { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let target = "https://www.cloudflare.com/cdn-cgi/trace"
        let available = targets.filter { liveTags[$0.id] != nil }
        var index = 0
        while index < available.count {
            let chunk = Array(available[index..<min(index + 8, available.count)])
            await withTaskGroup(of: (UUID, Int?).self) { group in
                for profile in chunk {
                    let tag = liveTags[profile.id] ?? ""
                    group.addTask { (profile.id, await ClashApi.delay(tag: tag, url: target)) }
                }
                for await (id, millis) in group {
                    guard let row = bulk.firstIndex(where: { $0.id == id }) else { continue }
                    bulk[row].result = ProbeResult(ok: millis != nil, millis: millis,
                                                   error: millis == nil ? "нет ответа через туннель" : nil)
                    bulk[row].done = true
                }
            }
            index += 8
        }
        append("параллельный пинг: \(available.count) серверов")
        return rest
    }

    /// Поочерёдная проверка: старт профиля → проба → стоп.
    private func checkSequential(_ profiles: [Profile], limitTransport: Bool = false) async {
        guard !profiles.isEmpty else { return }
        var wireturnChecked = 0
        for profile in profiles {
            guard let index = bulk.firstIndex(where: { $0.id == profile.id }) else { continue }
            append("проверка: \(profile.name) [\(profile.kind.title)]")
            if limitTransport, Self.needsTransport(profile) {
                if wireturnChecked >= 8 {
                    bulk[index].note = "в серии пропущен: не больше 8 VK-авторизаций подряд"
                    bulk[index].done = true
                    append("пропуск: \(profile.name) — лимит капчи VK на серию")
                    continue
                }
                wireturnChecked += 1
            }
            start(profile: profile)
            guard await waitListening() else {
                bulk[index].note = lastError ?? "ядро не слушает \(socksAddress)"
                bulk[index].result = ProbeResult(ok: false, error: lastError)
                bulk[index].done = true
                stop()
                continue
            }
            let deadline = Date().addingTimeInterval(Self.needsTransport(profile) ? 40 : 12)
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
    }

    /// Замер скорости: честный тест — качаем файл через этот сервер.
    /// Он поднимает именно выбранный профиль, поэтому активное соединение на время теста рвётся.
    func measureSpeed(profile: Profile, megabytes: Int = 10) async {
        guard speedRunning == nil else { return }
        speedRunning = profile.id
        defer { speedRunning = nil }
        let wasActive = activeProfileID == profile.id
        start(profile: profile)
        guard await waitListening() else {
            lastError = "скорость: ядро не слушает \(socksAddress)"
            return
        }
        let port = proxyPort
        if let result = await Self.download(bytes: megabytes * 1_000_000, port: port) {
            speed[profile.id] = result
            append("скорость: \(profile.name) → \(String(format: "%.1f", result.mbps)) Мбит/с")
        } else {
            append("скорость: \(profile.name) → не удалось скачать тестовый файл")
        }
        if !wasActive { stop() }
    }

    /// Скачивание тестового файла через локальный прокси: считаем по фактическим байтам.
    private static func download(bytes: Int, port: Int) async -> SpeedResult? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let session = URLSession(configuration: configuration)
        let clock = Date()
        guard let (data, _) = try? await session.data(from: url), !data.isEmpty else { return nil }
        let seconds = max(Date().timeIntervalSince(clock), 0.001)
        let mbps = Double(data.count) * 8 / seconds / 1_000_000
        return SpeedResult(mbps: mbps, bytes: Int64(data.count), seconds: seconds)
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

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
    /// Тег активного сервера в живом конфиге: «Соединения» показывают его как proxy.
    @Published private(set) var selectedTag: String?
    /// Тег ядра → имя сервера, чтобы в «Соединениях» не было s1/s2.
    @Published private(set) var tagNames: [String: String] = [:]
    /// Локальный порт пробы для сервера из живого конфига: пинг идёт в свой инбаунд,
    /// поэтому соединение не рвётся, а замер — это RTT, а не «хендшейк + запрос».
    private var probePorts: [UUID: Int] = [:]
    /// Активный профиль: по нему восстанавливаем `final` после перезапуска конфига.
    private(set) var activeProfileID: UUID?
    /// Профиль маршрутизации: его папки компилируются в правила при сборке живого конфига.
    private var routePlan: RoutePlan?
    /// Скачанные наборы правил (имя → путь): на них ссылаются папки с атрибутом `rule_set`.
    private var routeRuleSetPaths: [String: String] = [:]
    private lazy var turnable = TurnableEngine { [weak self] line in
        Task { @MainActor in self?.append(line) }
    }

    /// Транспорт Turnable для WireTurn-профилей: sing-box ждёт его на 127.0.0.1:9000.
    static let turnablePort = 9000

    /// Результат замера скорости: скачивание и отдача.
    struct SpeedResult {
        var downMbps: Double
        var upMbps: Double
        var bytes: Int64
        var seconds: Double
    }

    /// Цель пинга и параметры теста скорости берём из настроек.
    static var pingTarget: String {
        UserDefaults.standard.string(forKey: "prefs.pingTarget") ?? "https://1.1.1.1/cdn-cgi/trace"
    }

    /// Зеркала для теста скорости: берём первое, которое ответило.
    /// Cloudflare в России часто недоступен, поэтому TELE2 идёт первым.
    static var speedMirrors: [String] {
        let custom = UserDefaults.standard.string(forKey: "prefs.speedURL") ?? ""
        var list: [String] = []
        if !custom.isEmpty { list.append(custom) }
        // TELE2 с этого хоста не отвечает (проверено: code=000), Hetzner и
        // thinkbroadband тоже — рабочим остаётся Cloudflare.
        list.append("https://speed.cloudflare.com/__down")
        return list
    }

    static var speedUploadURL: String {
        UserDefaults.standard.string(forKey: "prefs.speedUploadURL") ?? "https://speed.cloudflare.com/__up"
    }

    static var speedMegabytes: Int {
        let stored = UserDefaults.standard.integer(forKey: "prefs.speedMB")
        return stored == 0 ? 10 : stored
    }

    /// Какое ядро сейчас работает — показываем в состоянии.
    @Published private(set) var activeCoreName = "—"
    /// Идёт серия проверок: интерфейс не должен показывать каждый проверяемый сервер как активный.
    @Published private(set) var probing = false
    /// Просьба остановить серию проверок или тестов скорости.
    private var cancelRequested = false
    /// Задача текущего замера: отмена должна прерывать запросы, а не выставлять флаг.
    private var measurementTask: Task<Void, Never>?

    /// Серия проверок отдельной задачей: её можно прервать кнопкой отмены.
    func runCheckAll(profiles: [Profile], onFinish: (() -> Void)? = nil) {
        measurementTask?.cancel()
        measurementTask = Task { [weak self] in
            await self?.checkAll(profiles: profiles)
            guard !Task.isCancelled else { return }
            onFinish?()
        }
    }

    /// Тест скорости по всем серверам — тоже отдельной задачей.
    func runSpeedAll(profiles: [Profile]) {
        measurementTask?.cancel()
        measurementTask = Task { [weak self] in
            guard let self else { return }
            for profile in profiles where !Task.isCancelled {
                await self.measureSpeed(profile: profile)
            }
        }
    }

    /// Пинг одного сервера из строки списка. Идёт тем же путём, что и серия проверок:
    /// у endpoint-профилей свои таймауты, повторы и цель без DNS — а не «12 секунд на всё».
    func runCheck(profile: Profile) {
        // Серия уже идёт — не рвём её одиночным пингом: строка и так будет измерена ею.
        guard !bulkRunning else { return }
        measurementTask?.cancel()
        if !bulk.contains(where: { $0.id == profile.id }) {
            bulk.append(BulkRow(id: profile.id, name: profile.name,
                                badge: profile.badge ?? profile.kind.title))
        }
        measurementTask = Task { [weak self] in
            guard let self else { return }
            let owned = !self.bulkRunning
            if owned {
                self.bulkRunning = true
                self.cancelRequested = false
            }
            await self.checkSequential([profile])
            if owned {
                self.bulkRunning = false
                self.probing = false
            }
        }
    }

    /// Отмена с кнопки: прерываем задачу замера, её запросы и ядро.
    func cancelMeasurements() {
        cancelRequested = true
        measurementTask?.cancel()
        measurementTask = nil
        // Обрыв самой загрузки: без этого файл на 10 МБ доезжает до конца.
        Self.abortSpeedSession()
        // Кружок «идёт замер» снимается только результатом строки, а при отмене результата
        // не будет — поэтому закрываем все ожидающие строки сами, иначе они висят со
        // спиннером до следующей проверки.
        for index in bulk.indices where !bulk[index].done {
            bulk[index].done = true
            bulk[index].note = "отменено"
        }
        if !bulk.isEmpty { append("проверка отменена") }
        bulkRunning = false
        speedRunning = nil
        probing = false
        stop()
    }
    /// Когда поднялось текущее соединение — для «сколько сервер активен».
    @Published private(set) var connectedSince: Date?
    /// Сколько активный сервер держится (секунды), для карточки подключения.
    var uptime: Int {
        guard let connectedSince else { return 0 }
        return Int(Date().timeIntervalSince(connectedSince))
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
    static let singboxKinds: Set<ProfileKind> = [.vless, .hysteria2, .mieru, .wireguard, .amneziawg, .custom]

    /// Запуск профиля. `pool` — остальные серверы: они добавляются в тот же конфиг,
    /// чтобы пинги не требовали перезапуска ядра. `plan` — профиль маршрутизации: его папки
    /// становятся правилами в том же конфиге.
    /// Итоговый выход одиночного конфига: `route.final` из собранного JSON.
    private static func finalTag(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = root["route"] as? [String: Any] else { return nil }
        return route["final"] as? String
    }

    private func names(for tags: [UUID: String], in profiles: [Profile]) -> [String: String] {
        var names: [String: String] = [:]
        for profile in profiles {
            if let tag = tags[profile.id] { names[tag] = profile.name }
        }
        return names
    }

    func start(profile: Profile, pool: [Profile] = [], plan: RoutePlan? = nil,
               ruleSetPaths: [String: String] = [:]) {
        if let plan { routePlan = plan }
        if !ruleSetPaths.isEmpty { routeRuleSetPaths = ruleSetPaths }
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
            if !Self.needsTransport(profile), candidates.count > 1,
               let built = try? ConfigBuilder.buildLive(profiles: candidates, selected: profile,
                                                        plan: routePlan, ruleSetPaths: routeRuleSetPaths) {
                config = built.json
                liveTags = built.tags
                selectedTag = built.tags[profile.id]
                tagNames = names(for: built.tags, in: candidates)
                probePorts = built.probePorts
                append("ядро: \(candidates.count) серверов в одном конфиге, активен \(profile.name)")
                append("маршрут: \(routePlan?.name ?? "—"), папок \(routePlan?.rules.count ?? 0)")
            } else {
                if !Self.needsTransport(profile), candidates.count > 1 {
                    append("общий конфиг не собрался — поднимаю один сервер")
                }
                config = try ConfigBuilder.build(profile: profile, plan: routePlan,
                                                 ruleSetPaths: routeRuleSetPaths)
                liveTags = [:]
                // Тег выхода в одиночном конфиге — из route.final: для WireGuard это
                // «wg-out». Без этой карты «Соединения» показывали сырой тег вместо proxy.
                let singleTag = Self.finalTag(in: config) ?? "proxy"
                selectedTag = singleTag
                tagNames = [singleTag: profile.name]
                probePorts = [:]
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
            if !probing {
                activeName = profile.name
                connectedSince = Date()
            }
            activeProfileID = profile.id
            activeCoreName = "sing-box"
            // Узел хендшейка — в журнал: ядро адрес не печатает, а без него мёртвый WARP не отличить
            // от «не разрешился домен».
            if let peer = ConfigBuilder.endpointPeerLine(profile) {
                append(peer)
            }
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

    /// Во время серии проверок Xray работает вместе с sing-box (как в настольном Throne, где
    /// оба ядра стартуют одновременно), поэтому `stop()` его не гасит до конца серии.
    private var keepXray = false

    private func stopXrayIfIdle() {
        guard !keepXray, LibboxXrayIsRunning() else { return }
        var error: NSError?
        _ = LibboxXrayStop(&error)
        append("xray: остановлен")
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
            activeCoreName = "Xray"
            append("ядро: Xray (VLESS + XHTTP)")
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
            activeCoreName = "WireTurn (транспорт)"
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
        stopXrayIfIdle()
        activeProfileID = nil
        liveTags = [:]
        selectedTag = nil
        tagNames = [:]
        probePorts = [:]
        activeCoreName = "—"
        connectedSince = nil
        turnable.stop()
        stopXrayIfIdle()
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

    /// Профили, задержку которых можно спросить прямо в живом конфиге: у каждого свой пробный
    /// вход, а route.rules ссылается и на outbound, и на endpoint — то есть WireGuard тоже.
    /// Своё ядро/транспорт только у Xray и WireTurn/Turnable.
    static let parallelKinds: Set<ProfileKind> = [.vless, .hysteria2, .mieru, .wireguard, .amneziawg, .custom]

    /// Проверка всех серверов: сначала параллельно в уже поднятом ядре, потом WireGuard и Xray
    /// по очереди, и в самом конце WireTurn — он долгий (VK-авторизация, капча, SRTP).
    func checkAll(profiles: [Profile]) async {
        guard !bulkRunning, !profiles.isEmpty else { return }
        bulkRunning = true
        probing = true
        cancelRequested = false
        defer { bulkRunning = false; probing = false }
        bulk = profiles.map { BulkRow(id: $0.id, name: $0.name, badge: $0.badge ?? $0.kind.title) }

        // Xray — отдельное ядро, оно не мешает sing-box: поднимаем оба сразу и меряем
        // XHTTP-серверы параллельно с остальными (в Throne PC Xray стартует в том же заходе).
        let xrayPorts = startXrayPool(profiles)
        keepXray = !xrayPorts.isEmpty
        async let xrayProbe = probeXray(profiles, ports: xrayPorts)
        let rest = await measure(profiles)
        let xrayLeft = await xrayProbe
        keepXray = false

        let plain = rest.filter { !Self.needsTransport($0) && $0.kind != .xray }
        let xray = xrayLeft.filter { $0.kind == .xray }
        let turnable = rest.filter { Self.needsTransport($0) }

        await checkSequential(plain)
        await checkSequential(xray)
        await checkSequential(turnable, limitTransport: true)
        append("проверка всех серверов завершена")
    }

    /// Общий конфиг Xray на все XHTTP-профили: один запуск ядра, у каждого сервера свой
    /// socks-вход. Возвращает порты; пустой словарь — поднять не удалось (тогда по одному).
    private func startXrayPool(_ profiles: [Profile]) -> [UUID: Int] {
        let targets = profiles.filter { $0.kind == .xray }
        guard !targets.isEmpty else { return [:] }
        var entries: [(id: UUID, link: VLESSLink)] = []
        for profile in targets {
            guard let link = try? VLESSLink.parse(profile.payload) else { continue }
            entries.append((profile.id, link))
        }
        guard !entries.isEmpty else { return [:] }
        let built = XrayConfig.buildPool(links: entries)
        var error: NSError?
        guard LibboxXrayStart(built.json, &error) else {
            append("xray: общий конфиг не поднялся — проверю по одному")
            return [:]
        }
        append("xray: общее ядро на \(built.ports.count) серверов")
        return built.ports
    }

    /// Замер Xray-серверов через свои входы. Возвращает тех, кого померить не вышло.
    private func probeXray(_ profiles: [Profile], ports: [UUID: Int]) async -> [Profile] {
        guard !ports.isEmpty else { return profiles }
        var measured: Set<UUID> = []
        await withTaskGroup(of: (UUID, ProbeResult?).self) { group in
            for (id, port) in ports where !cancelRequested && !Task.isCancelled {
                group.addTask {
                    // Ядро только поднялось: входы могут слушать не сразу, поэтому три подхода.
                    for attempt in 0..<3 {
                        if let result = await Probe.timed(port: port, timeout: 8) {
                            return (id, result)
                        }
                        if attempt < 2 { try? await Task.sleep(nanoseconds: 700_000_000) }
                    }
                    return (id, nil as ProbeResult?)
                }
            }
            for await (id, result) in group {
                measured.insert(id)
                guard let row = bulk.firstIndex(where: { $0.id == id }) else { continue }
                if let result {
                    bulk[row].result = result
                } else {
                    bulk[row].result = ProbeResult(ok: false, error: "нет ответа")
                }
                bulk[row].done = true
            }
        }
        if !measured.isEmpty { append("xray: замерено \(measured.count)") }
        return profiles.filter { $0.kind != .xray || !measured.contains($0.id) }
    }

    /// Параллельный замер. Если ядро уже держит все серверы в живом конфиге — пингуем
    /// каждый через его собственный инбаунд (`probe-<tag>` → правило → этот сервер).
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

        // Ждём, пока ядро откроет порты: и основной, и пробные поднимаются вместе.
        guard await waitListening() else { return profiles }

        let available = targets.filter { probePorts[$0.id] != nil }
        var measured: Set<UUID> = []
        // Все замеры разом: у каждого сервера свой вход, поэтому они не мешают друг другу.
        // Внутри Probe — прогрев соединения и минимум из нескольких проб, то есть RTT.
        await withTaskGroup(of: (UUID, ProbeResult?).self) { group in
            for profile in available where !cancelRequested && !Task.isCancelled {
                guard let port = probePorts[profile.id] else { continue }
                // 8 с: один мёртвый сервер не должен задерживать всю пачку — иначе
                // «параллельный» замер ждёт его одного и выглядит как зависание.
                // Endpoint-профилям — только IP-литерал, иначе DNS съедает 10 с таймаута.
                let addressOnly = ConfigBuilder.isEndpointProfile(profile)
                group.addTask {
                    (profile.id, await Probe.timed(port: port, timeout: 8, addressOnly: addressOnly))
                }
            }
            for await (id, result) in group {
                measured.insert(id)
                guard let row = bulk.firstIndex(where: { $0.id == id }) else { continue }
                if let result {
                    bulk[row].result = result
                } else if let tag = liveTags[id] {
                    // Резерв, если пробный вход почему-то молчит: Clash-задержка. В неё входит
                    // хендшейк (цифры будут выше), но строка не останется без ответа.
                    let millis = await ClashApi.delay(tag: tag, url: Self.pingTarget)
                    bulk[row].result = ProbeResult(ok: millis != nil, millis: millis,
                                                   error: millis == nil ? "нет ответа" : nil)
                } else {
                    bulk[row].result = ProbeResult(ok: false, error: "нет ответа")
                }
                bulk[row].done = true
            }
        }
        append("параллельный пинг: \(measured.count) серверов")

        // Кого нельзя проверить своим входом (WireGuard-эндпоинты, панельные JSON без
        // outbound'а) — отдаём в поочерёдную проверку, иначе строка осталась бы без ответа.
        var remaining = rest
        for profile in targets where !measured.contains(profile.id) {
            if !remaining.contains(where: { $0.id == profile.id }) { remaining.append(profile) }
        }
        return remaining
    }

    /// Поочерёдная проверка: старт профиля → проба → стоп.
    private func checkSequential(_ profiles: [Profile], limitTransport: Bool = false) async {
        guard !profiles.isEmpty else { return }
        var wireturnChecked = 0
        for profile in profiles {
            if cancelRequested || Task.isCancelled { return }
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
            let transport = Self.needsTransport(profile)
            // Endpoint-профилям (WireGuard, WARP, AWG, WireTurn/Turnable) шлём IP-литерал: домена
            // в схеме нет вовсе, поэтому DNS-таймауты 10 с из лога больше не участвуют, а живой
            // эндпоинт отвечает за 2–4 с. Мёртвый (WARP без валидных ключей) не отвечает никогда —
            // 16 с хватает, чтобы это увидеть, и не задерживает весь прогон.
            let endpointKind = ConfigBuilder.isEndpointProfile(profile)
            let deadline = Date().addingTimeInterval(transport ? 40 : (endpointKind ? 16 : 12))
            var result = await Probe.timed(port: proxyPort, timeout: transport ? 20 : (endpointKind ? 6 : 12),
                                           addressOnly: endpointKind)
                ?? ProbeResult(ok: false, error: "таймаут проверки")
            while !result.ok, Date() < deadline {
                // Отмену проверяем на каждом круге: снятая задача не должна доедать дедлайн.
                if cancelRequested || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if cancelRequested || Task.isCancelled { break }
                result = await Probe.timed(port: proxyPort, timeout: 8, addressOnly: endpointKind) ?? result
            }
            bulk[index].result = result
            bulk[index].done = true
            append("итог: \(profile.name) → \(result.summary)")
            stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Проверка уже поднятого соединения: IP, страна и пинг без перезапуска ядра.
    /// Вызывается автоматически после подключения, чтобы карточка сразу показывала выход.
    func probeActive(profile: Profile) async {
        guard running, !transportOnly else { return }
        let port = proxyPort
        // Для endpoint-профилей — по IP-литералу, без DNS (см. Probe.addressOnly).
        let result = await Probe.timed(port: port, timeout: 12,
                                       addressOnly: ConfigBuilder.isEndpointProfile(profile))
            ?? ProbeResult(ok: false, error: "нет ответа")
        if let index = bulk.firstIndex(where: { $0.id == profile.id }) {
            bulk[index].result = result
            bulk[index].done = true
        } else {
            bulk.append(BulkRow(id: profile.id, name: profile.name,
                                badge: profile.badge ?? profile.kind.title,
                                result: result, note: nil, done: true))
        }
        append("выход: \(profile.name) → \(result.summary)")
    }

    /// Замер скорости: скачиваем и отправляем файл через этот сервер.
    /// Это честный тест трафика, поэтому он поднимает именно выбранный профиль,
    /// и активное соединение на время замера прерывается.
    func measureSpeed(profile: Profile) async {
        guard speedRunning == nil else { return }
        cancelRequested = false
        speedRunning = profile.id
        defer { speedRunning = nil }
        let wasActive = activeProfileID == profile.id
        start(profile: profile)
        guard await waitListening() else {
            lastError = "скорость: ядро не слушает \(socksAddress)"
            return
        }
        let port = proxyPort
        let megabytes = Self.speedMegabytes

        guard let download = await Self.download(megabytes: megabytes, port: port) else {
            append("скорость: \(profile.name) → скачивание не удалось")
            if !wasActive { stop() }
            return
        }
        let upload = await Self.upload(megabytes: max(megabytes / 2, 1), port: port)
        speed[profile.id] = SpeedResult(downMbps: download.mbps,
                                        upMbps: upload?.mbps ?? 0,
                                        bytes: download.bytes + (upload?.bytes ?? 0),
                                        seconds: download.seconds + (upload?.seconds ?? 0))
        let down = String(format: "%.1f", download.mbps)
        let up = upload.map { String(format: "%.1f", $0.mbps) } ?? "—"
        append("скорость: \(profile.name) → ↓ \(down) Мбит/с · ↑ \(up) Мбит/с")
        if !wasActive { stop() }
    }

    private struct Leg {
        let mbps: Double
        let bytes: Int64
        let seconds: Double
    }

    private static func proxySession(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let session = URLSession(configuration: configuration)
        // Держим текущую сессию, чтобы отмена могла её оборвать: снятие Task не прерывает
        // уже начатую загрузку на 10 МБ — она доедет до конца (до 120 с), и кнопка
        // «отмена» выглядит неработающей.
        speedSessionLock.lock()
        speedSession?.invalidateAndCancel()
        speedSession = session
        speedSessionLock.unlock()
        return session
    }

    private static var speedSession: URLSession?
    private static let speedSessionLock = NSLock()

    /// Оборвать текущий замер скорости, если он идёт.
    static func abortSpeedSession() {
        speedSessionLock.lock()
        speedSession?.invalidateAndCancel()
        speedSession = nil
        speedSessionLock.unlock()
    }

    /// Скачивание: пробуем зеркала по очереди, пока одно не ответит.
    private static func download(megabytes: Int, port: Int) async -> Leg? {
        let bytes = megabytes * 1_000_000
        let session = proxySession(port: port)
        for mirror in speedMirrors {
            let candidate = mirror.contains("%d") ? mirror.replacingOccurrences(of: "%d", with: String(bytes))
                : mirror + (mirror.contains("?") ? "&" : "?") + "bytes=" + String(bytes)
            guard let url = URL(string: candidate) else { continue }
            let clock = Date()
            guard let (data, _) = try? await session.data(from: url), data.count > 100_000 else { continue }
            let seconds = max(Date().timeIntervalSince(clock), 0.001)
            return Leg(mbps: Double(data.count) * 8 / seconds / 1_000_000,
                       bytes: Int64(data.count),
                       seconds: seconds)
        }
        return nil
    }

    private static func upload(megabytes: Int, port: Int) async -> Leg? {
        guard let url = URL(string: speedUploadURL) else { return nil }
        let session = proxySession(port: port)
        let payload = Data(count: megabytes * 1_000_000)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let clock = Date()
        guard let (_, response) = try? await session.upload(for: request, from: payload) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status < 400 else { return nil }
        let seconds = max(Date().timeIntervalSince(clock), 0.001)
        return Leg(mbps: Double(payload.count) * 8 / seconds / 1_000_000,
                   bytes: Int64(payload.count),
                   seconds: seconds)
    }

    /// Проверка одного профиля идёт через `checkSequential` (см. `runCheck`): у endpoint-профилей
    /// там свои таймауты, повторы и цель без DNS. Отдельный упрощённый путь удалён — он мерил
    /// WireGuard теми же 12 секундами, что и VLESS, и всегда показывал «Недоступен».

    /// Ждём, пока ядро откроет локальный порт (до 10 с), не блокируя интерфейс.
    /// Порт локального входа для сервера: у активного — основной, у остальных —
    /// пробный (он существует, только когда ядро держит пул серверов).
    func trafficPort(for id: UUID?) -> Int? {
        guard let id else { return proxyPort }
        if id == activeProfileID { return proxyPort }
        return probePorts[id]
    }

    /// Пересобирает ядро с пулом серверов, чтобы у каждого появился свой пробный вход.
    /// Нужно тесту трафика через конкретный сервер; счётчики сессии при этом не теряются.
    @discardableResult
    func prepareTrafficPool(profiles: [Profile]) async -> Bool {
        let pool = profiles.filter { Self.singboxKinds.contains($0.kind) }
        guard pool.count > 1, running else { return false }
        guard let anchor = pool.first(where: { $0.id == activeProfileID }) ?? pool.first else {
            return false
        }
        start(profile: anchor, pool: pool)
        guard running else { return false }
        return await waitListening()
    }

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

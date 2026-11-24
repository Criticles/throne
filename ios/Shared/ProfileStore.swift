import Foundation

/// Профили в dev-режиме: импорт из текста/по URL, выбор активного, сохранение между запусками.
///
/// Хранятся в UserDefaults приложения. Внутри — ключи и пароли из подписки,
/// поэтому по умолчанию это только локальное хранилище на устройстве.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var status: String = ""
    @Published private(set) var loading = false
    /// Полный журнал импорта: запрос → ответ панели → что распознали → что приняли/отбросили.
    @Published private(set) var importLog: String = ""
    /// Подписки — «папки» списка серверов; профили помнят свою папку в `group`.
    @Published private(set) var subscriptions: [Subscription] = []

    private let profilesKey = "dev.profiles"
    private let selectedKey = "dev.selectedProfile"
    private let subscriptionsKey = "dev.subscriptions"
    private let kindsKey = "dev.allowedKinds"

    /// Профили, добавленные ссылкой из буфера, живут в этой папке.
    static let manualFolder = "Вручную"

    /// Какие протоколы принимать при импорте. Настройка пользователя: по умолчанию все.
    @Published var allowedKinds: Set<ProfileKind> {
        didSet { defaults.set(allowedKinds.map { $0.rawValue }, forKey: kindsKey) }
    }
    private let defaults = UserDefaults.standard

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: "dev.allowedKinds") ?? []
        let kinds = stored.compactMap { ProfileKind(rawValue: $0) }
        allowedKinds = kinds.isEmpty ? Set(ProfileKind.allCases) : Set(kinds)
        load()
    }

    var selected: Profile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
    }

    /// Папки для переключателя сверху: реальные подписки + «Вручную».
    var folders: [String] {
        var names = Set<String>()
        for profile in profiles { names.insert(profile.group ?? Self.manualFolder) }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func count(in folder: String) -> Int {
        profiles.filter { ($0.group ?? Self.manualFolder) == folder }.count
    }

    func profiles(in folder: String) -> [Profile] {
        profiles.filter { ($0.group ?? Self.manualFolder) == folder }
    }

    func toggleFavorite(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].favorite.toggle()
        save()
    }

    func setNote(_ text: String, for profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].note = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// Автообновление подписок: по таймеру из настроек подписки.
    /// Вызывается при запуске и пока приложение открыто — фоновых задач iOS не даёт.
    func autoUpdateIfNeeded() async {
        guard !loading else { return }
        let now = Date()
        for subscription in subscriptions where subscription.autoUpdate {
            if let updated = subscription.updated {
                let interval = TimeInterval(max(subscription.intervalHours, 1) * 3600)
                if now.timeIntervalSince(updated) < interval { continue }
            }
            await refresh(subscription)
        }
    }

    func setAutoUpdate(_ enabled: Bool, intervalHours: Int, for subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].autoUpdate = enabled
        subscriptions[index].intervalHours = max(1, intervalHours)
        save()
    }

    func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        if selectedID == profile.id { selectedID = profiles.first?.id }
        save()
        status = "удалён: \(profile.name)"
    }

    /// Обновить одну подписку по её ссылке.
    func refresh(_ subscription: Subscription) async {
        await importFromURL(subscription.url, name: subscription.name)
    }

    /// Удалить подписку вместе со всеми её серверами.
    func remove(_ subscription: Subscription) {
        profiles.removeAll { $0.group == subscription.name }
        subscriptions.removeAll { $0.id == subscription.id }
        if let selectedID, !profiles.contains(where: { $0.id == selectedID }) {
            self.selectedID = profiles.first?.id
        }
        save()
        status = "подписка удалена: \(subscription.name)"
    }

    /// Имя папки по ссылке подписки: первый сегмент хоста — так же, как зовёт её панель.
    static func folderName(for url: String) -> String {
        guard let host = URL(string: url)?.host else { return "Подписка" }
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.isEmpty ? host : first
    }

    func select(_ id: UUID) {
        selectedID = id
        defaults.set(id.uuidString, forKey: selectedKey)
    }

    @discardableResult
    func importFromText(_ text: String) -> Int {
        let parsed = ProfileParser.parse(text: text)
        guard !parsed.isEmpty else {
            status = "в тексте не нашлось поддерживаемых профилей"
            return 0
        }
        let added = merge(parsed)
        status = "добавлено профилей: \(added) (всего \(profiles.count))"
        return added
    }

    /// Одно поле ввода на всё: http(s) — подписка, иначе — одна или несколько share-ссылок.
    func importAny(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            await importFromURL(trimmed)
        } else {
            importFromText(trimmed)
        }
    }

    func importFromURL(_ raw: String, name: String? = nil) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else {
            status = "нужен http(s)-адрес подписки"
            return
        }
        loading = true
        defer { loading = false }

        importLog = ""
        var userinfo: String?
        let folder = name ?? Self.folderName(for: trimmed)
        log("импорт подписки: \(trimmed)")
        log("    папка: \(folder)")

        var added = 0
        var problems: [String] = []

        do {
            let first = try await fetch(url, userAgent: "v2rayNG/1.8.5")
            let list = first.text
            userinfo = first.response?.value(forHTTPHeaderField: "subscription-userinfo")
            if list.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                problems.append("вместо подписки пришёл HTML")
            } else {
                log("  формат: \(ProfileParser.describe(list))")
                added += importParsed(ProfileParser.parse(text: list), group: folder)
            }
        } catch {
            problems.append("список: \(Self.describe(error))")
        }

        // Панель ориентируется на User-Agent. Десктопный Throne шлёт «Throne/<версия>»,
        // поэтому пробуем его UA первым: с ним выдача совпадает с тем, что видно в Throne на ПК
        // (в частности, там появляется Mieru).
        for userAgent in ["Throne/1.1.0", "Throne/0.1 (iOS)"] {
            do {
                let configText = try await fetch(url, userAgent: userAgent).text
                guard configText.contains("\"outbounds\"") else { continue }
                log("  формат: \(ProfileParser.describe(configText))")
                added += importParsed(ProfileParser.parse(text: configText), group: folder)
                break
            } catch {
                problems.append("конфиг (\(userAgent)): \(Self.describe(error))")
            }
        }


        // Панель отдаёт AmneziaWG только клиенту YPtun (проверено: 3 ссылки вместо 2).
        do {
            let yptunList = try await fetch(url, userAgent: "YPtun/3.7.0").text
            if !yptunList.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                log("  формат: \(ProfileParser.describe(yptunList))")
                added += importParsed(ProfileParser.parse(text: yptunList), group: folder)
            }
        } catch {
            problems.append("AWG: \(Self.describe(error))")
        }

        log("  -- Turnable: сначала wireturn (с WARP-обвязкой), затем turnable как дополнение")

        // Turnable-узлы есть ТОЛЬКО в отдельных форматах: ни в xray-списке, ни в Clash,
        // ни в sing-box их не бывает (проверено: 2 / 4 / 4 узла против 6 здесь).
        // `wireturn` — профили Throne с WARP-обвязкой, `turnable` — их «сырые» конфиги;
        // без WARP-аккаунта панель отвечает на wireturn 422, тогда берём второй формат.
        // Движка Turnable в сборке нет, но ключи обязаны быть в списке — с пометкой.
        for format in ["wireturn"] {
            guard let turnableURL = Self.withQuery(url, [("format", format)]) else { continue }
            do {
                let text = try await fetch(turnableURL, userAgent: "Throne/1.1.0").text
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { continue }
                log("  формат: \(ProfileParser.describe(text))")
                added += importParsed(ProfileParser.parse(text: text), group: folder)
                // Не break: запрашиваем оба формата. wireturn идёт первым, поэтому дедуп по имени
                // оставляет именно его (в нём есть WG-обвязка), а turnable добавит только те узлы,
                // которых в wireturn нет — если такие вообще найдутся.
            } catch {
                if (error as NSError).code != 422 {
                    // 422 = у этого пользователя нет узлов в этом формате, это не ошибка.
                    problems.append("\(format): \(Self.describe(error))")
                }
            }
        }

        recordSubscription(url: trimmed, name: folder, userinfo: userinfo)
        if added > 0 {
            status = "добавлено профилей: \(added) (всего \(profiles.count))"
        } else {
            status = problems.isEmpty
                ? "в подписке не нашлось поддерживаемых профилей"
                : problems.joined(separator: " · ")
        }
    }

    func removeAll() {
        profiles = []
        subscriptions = []
        selectedID = nil
        defaults.removeObject(forKey: profilesKey)
        defaults.removeObject(forKey: selectedKey)
        defaults.removeObject(forKey: subscriptionsKey)
        status = "список очищен"
    }

    // MARK: - Внутреннее

    private func log(_ line: String) {
        importLog += line + "\n"
        // Импорт и логи ядра теперь в одном потоке — не нужно прыгать между двумя блоками.
        LogStore.shared.append("импорт: \(line)", stamp: false)
    }

    private func fetch(_ url: URL, userAgent: String) async throws -> (text: String, response: HTTPURLResponse?) {
        log("GET \(url.absoluteString)")
        log("    User-Agent: \(userAgent)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
        log("    → HTTP \(code) · \(type) · \(data.count) Б")
        guard code == 200 else {
            throw NSError(domain: "orbita.subscription", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            log("    → ответ не в UTF-8")
            throw NSError(domain: "orbita.subscription", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "ответ не в UTF-8"])
        }
        return (text, http)
    }

    @discardableResult
    private func importParsed(_ parsed: [Profile], group: String? = nil) -> Int {
        guard !parsed.isEmpty else {
            log("  → профилей не найдено")
            return 0
        }
        let names = parsed.map { "\($0.kind.title): \($0.name)" }.joined(separator: " | ")
        log("  → разобрано \(parsed.count): \(names)")

        // Пользователь может выключить ненужные протоколы в настройках — тогда они
        // не попадают в список, а не просто прячутся в интерфейсе.
        let allowed = parsed.filter { allowedKinds.contains($0.kind) }
        if allowed.count != parsed.count {
            log("  → отфильтровано по настройкам протоколов: \(parsed.count - allowed.count)")
        }
        guard !allowed.isEmpty else { return 0 }
        return merge(allowed, group: group)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    /// Копия URL подписки с подменёнными параметрами запроса: панель выбирает формат по `?format=`.
    private static func withQuery(_ url: URL, _ pairs: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        for (name, value) in pairs {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.url
    }

    /// `?format=turnable` и `?format=wireturn` отдают одни и те же серверы в двух обёртках —
    /// поэтому Turnable-профили сравниваем по имени, иначе список удваивается.
    ///
    /// Остальные — по «личности сервера» (протокол + хост + порт): панель присылает один и тот же
    /// сервер дважды, ссылкой в base64-списке и куском JSON-конфига, и без этого в списке
    /// оказывались два одинаковых VLESS и две одинаковые Hysteria2.
    private func dedupeKey(_ profile: Profile) -> String {
        switch profile.kind {
        case .turnable, .wireturn:
            // Это не дубли: wireturn несёт WG-обвязку, turnable — «сырой» конфиг.
            // Пользователь сам увидит, какой путь рабочий, поэтому держим оба.
            return "\(profile.kind.rawValue)|\(profile.name)"
        default:
            if let identity = Self.serverIdentity(profile.payload) {
                return identity
            }
            return "\(profile.kind.rawValue)|\(profile.name)|\(profile.payload)"
        }
    }

    /// Один сервер из payload профиля: либо share-ссылка, либо мини-конфиг с единственным выходом.
    private static func serverIdentity(_ payload: String) -> String? {
        fromMiniConfig(payload) ?? fromLink(payload)
    }

    private static func fromMiniConfig(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any]
        else { return nil }

        // Профиль «конфиг панели целиком» содержит urltest/selector и несколько выходов —
        // это не один сервер, у него своей личности быть не должно.
        let outbounds = (config["outbounds"] as? [[String: Any]] ?? []).filter { $0["server"] != nil }
        let endpoints = config["endpoints"] as? [[String: Any]] ?? []
        guard outbounds.count + endpoints.count == 1 else { return nil }

        if let outbound = outbounds.first,
           let type = outbound["type"] as? String,
           let server = outbound["server"] as? String,
           let port = (outbound["server_port"] ?? outbound["port"]) as? Int {
            return "\(family(type))|\(server)|\(port)"
        }
        if let endpoint = endpoints.first,
           let type = endpoint["type"] as? String,
           let peers = endpoint["peers"] as? [[String: Any]],
           let peer = peers.first,
           let server = peer["address"] as? String,
           let port = peer["port"] as? Int {
            return "\(family(type))|\(server)|\(port)"
        }
        return nil
    }

    private static func fromLink(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = String(trimmed[..<schemeEnd.lowerBound]).lowercased()
        var rest = String(trimmed[schemeEnd.upperBound...])
        // `amneziawg://<base64 от wg-quick>`: узла в authority нет, host и port лежат внутри INI.
        if scheme == "amneziawg", let config = WireGuardConfig.parse(trimmed) {
            return "wireguard|\(config.host)|\(config.port)"
        }
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        if let query = rest.firstIndex(of: "?") { rest = String(rest[..<query]) }
        // Хвостовой слэш (`hy2://user:pass@host:39518/`) иначе попадает в «порт»: 39518/ ≠ 39518.
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        guard let at = rest.lastIndex(of: "@") else { return nil }

        let authority = String(rest[rest.index(after: at)...])
        let parts = authority.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        let port = parts[1].split(separator: "-").first.map(String.init) ?? ""
        return "\(family(scheme))|\(String(parts[0]))|\(port)"
    }

    /// Имена протоколов в ссылке и в JSON не совпадают (`mierus` против `mieru`, `wg` против `wireguard`).
    private static func family(_ raw: String) -> String {
        switch raw.lowercased() {
        case "vless": return "vless"
        case "hysteria2", "hy2": return "hysteria2"
        case "mieru", "mierus": return "mieru"
        case "wg", "wireguard", "amneziawg": return "wireguard"
        case "trojan": return "trojan"
        case "shadowsocks", "ss": return "shadowsocks"
        default: return raw.lowercased()
        }
    }

    @discardableResult
    private func merge(_ incoming: [Profile], group: String? = nil) -> Int {
        var added = 0
        for candidate in incoming {
            var profile = candidate
            // Папка — свойство подписки, а не сервера: при обновлении той же подписки
            // профиль остаётся один, но переезжает в актуальную папку.
            if let group { profile.group = group }
            let key = dedupeKey(profile)
            if let index = profiles.firstIndex(where: { dedupeKey($0) == key }) {
                if let group, profiles[index].group != group {
                    profiles[index].group = group
                    save()
                }
                log("    дубль, пропущен: \(profile.name) [\(key)]")
                continue
            }
            profiles.append(profile)
            log("    принят: \(profile.name) [\(key)]")
            added += 1
        }
        if selectedID == nil {
            selectedID = profiles.first?.id
            defaults.set(selectedID?.uuidString, forKey: selectedKey)
        }
        if added > 0 {
            save()
        }
        return added
    }

    /// Подписка в списке одна на URL: повторный импорт только обновляет дату и счётчик.
    private func recordSubscription(url: String, name: String, userinfo: String? = nil) {
        let inFolder = profiles.filter { $0.group == name }.count
        let limits = Self.parseUserinfo(userinfo)
        if let index = subscriptions.firstIndex(where: { $0.url == url }) {
            subscriptions[index].name = name
            subscriptions[index].updated = Date()
            subscriptions[index].count = inFolder
            if let limits {
                subscriptions[index].upload = limits.upload
                subscriptions[index].download = limits.download
                subscriptions[index].total = limits.total
                subscriptions[index].expire = limits.expire
            }
        } else {
            var subscription = Subscription(name: name, url: url, updated: Date(), count: inFolder)
            if let limits {
                subscription.upload = limits.upload
                subscription.download = limits.download
                subscription.total = limits.total
                subscription.expire = limits.expire
            }
            subscriptions.append(subscription)
        }
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: subscriptionsKey)
        }
    }

    /// `subscription-userinfo: upload=1; download=2; total=3; expire=1760000000`
    static func parseUserinfo(_ raw: String?) -> (upload: Int64, download: Int64, total: Int64, expire: Date?)? {
        guard let raw, !raw.isEmpty else { return nil }
        var upload: Int64 = 0
        var download: Int64 = 0
        var total: Int64 = 0
        var expire: Date?
        for chunk in raw.split(separator: ";") {
            let pair = chunk.split(separator: "=")
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "upload": upload = Int64(value) ?? 0
            case "download": download = Int64(value) ?? 0
            case "total": total = Int64(value) ?? 0
            case "expire":
                if let stamp = Double(value), stamp > 0 {
                    expire = Date(timeIntervalSince1970: stamp)
                }
            default: break
            }
        }
        return (upload, download, total, expire)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
        // Счётчики в «Подписках» берём из фактического состава папок.
        if !subscriptions.isEmpty {
            for index in subscriptions.indices {
                subscriptions[index].count = profiles.filter { $0.group == subscriptions[index].name }.count
            }
            if let data = try? JSONEncoder().encode(subscriptions) {
                defaults.set(data, forKey: subscriptionsKey)
            }
        }
    }

    private func load() {
        if let data = defaults.data(forKey: profilesKey),
           let stored = try? JSONDecoder().decode([Profile].self, from: data) {
            // Turnable-профили убраны: панель отдаёт в них только транспорт без ключей WG,
            // туннель не собрать. Оставляем WireTurn (тот же транспорт + wgConfig).
            let cleaned = stored.filter { $0.kind != .turnable }
            profiles = cleaned
            if cleaned.count != stored.count {
                save()
                LogStore.shared.append("импорт: удалены Turnable-профили без ключей (\(stored.count - cleaned.count))", stamp: false)
            }
        }
        if let raw = defaults.string(forKey: selectedKey), let id = UUID(uuidString: raw) {
            selectedID = id
        }
        if let data = defaults.data(forKey: subscriptionsKey),
           let stored = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = stored
        }
    }
}

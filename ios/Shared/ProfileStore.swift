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

    private let profilesKey = "dev.profiles"
    private let selectedKey = "dev.selectedProfile"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    var selected: Profile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
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

    func importFromURL(_ raw: String) async {
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
        log("импорт подписки: \(trimmed)")

        var added = 0
        var problems: [String] = []

        do {
            let list = try await fetch(url, userAgent: "v2rayNG/1.8.5")
            if list.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                problems.append("вместо подписки пришёл HTML")
            } else {
                log("  формат: \(ProfileParser.describe(list))")
                added += importParsed(ProfileParser.parse(text: list))
            }
        } catch {
            problems.append("список: \(Self.describe(error))")
        }

        // Панель ориентируется на User-Agent. Десктопный Throne шлёт «Throne/<версия>»,
        // поэтому пробуем его UA первым: с ним выдача совпадает с тем, что видно в Throne на ПК
        // (в частности, там появляется Mieru).
        for userAgent in ["Throne/1.1.0", "Throne/0.1 (iOS)"] {
            do {
                let configText = try await fetch(url, userAgent: userAgent)
                guard configText.contains("\"outbounds\"") else { continue }
                log("  формат: \(ProfileParser.describe(configText))")
                added += importParsed(ProfileParser.parse(text: configText))
                break
            } catch {
                problems.append("конфиг (\(userAgent)): \(Self.describe(error))")
            }
        }


        // Панель отдаёт AmneziaWG только клиенту YPtun (проверено: 3 ссылки вместо 2).
        do {
            let yptunList = try await fetch(url, userAgent: "YPtun/3.7.0")
            if !yptunList.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                log("  формат: \(ProfileParser.describe(yptunList))")
                added += importParsed(ProfileParser.parse(text: yptunList))
            }
        } catch {
            problems.append("AWG: \(Self.describe(error))")
        }

        // Turnable-узлы есть ТОЛЬКО в отдельных форматах: ни в xray-списке, ни в Clash,
        // ни в sing-box их не бывает (проверено: 2 / 4 / 4 узла против 6 здесь).
        // `wireturn` — профили Throne с WARP-обвязкой, `turnable` — их «сырые» конфиги;
        // без WARP-аккаунта панель отвечает на wireturn 422, тогда берём второй формат.
        // Движка Turnable в сборке нет, но ключи обязаны быть в списке — с пометкой.
        for format in ["wireturn", "turnable"] {
            guard let turnableURL = Self.withQuery(url, [("format", format)]) else { continue }
            do {
                let text = try await fetch(turnableURL, userAgent: "Throne/1.1.0")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { continue }
                log("  формат: \(ProfileParser.describe(text))")
                added += importParsed(ProfileParser.parse(text: text))
                break  // второй формат отдал бы те же узлы: дедупликация по имени их схлопнет
            } catch {
                if (error as NSError).code != 422 {
                    // 422 = у этого пользователя нет узлов в этом формате, это не ошибка.
                    problems.append("\(format): \(Self.describe(error))")
                }
            }
        }

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
        selectedID = nil
        defaults.removeObject(forKey: profilesKey)
        defaults.removeObject(forKey: selectedKey)
        status = "список очищен"
    }

    // MARK: - Внутреннее

    private func log(_ line: String) {
        importLog += line + "
"
    }

    private func fetch(_ url: URL, userAgent: String) async throws -> String {
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
        return text
    }

    @discardableResult
    private func importParsed(_ parsed: [Profile]) -> Int {
        guard !parsed.isEmpty else {
            log("  → профилей не найдено")
            return 0
        }
        let names = parsed.map { "\($0.kind.title): \($0.name)" }.joined(separator: " | ")
        log("  → разобрано \(parsed.count): \(names)")
        return merge(parsed)
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
            return "turnable|\(profile.name)"
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
    private func merge(_ incoming: [Profile]) -> Int {
        var seen = Set(profiles.map { dedupeKey($0) })
        var added = 0
        for profile in incoming {
            let key = dedupeKey(profile)
            guard !seen.contains(key) else {
                log("    дубль, пропущен: \(profile.name) [\(key)]")
                continue
            }
            seen.insert(key)
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

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    private func load() {
        if let data = defaults.data(forKey: profilesKey),
           let stored = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = stored
        }
        if let raw = defaults.string(forKey: selectedKey), let id = UUID(uuidString: raw) {
            selectedID = id
        }
    }
}

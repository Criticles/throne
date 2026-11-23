import Foundation

/// Разбор всего, что может лежать в подписке: по одной share-ссылке на строку,
/// либо JSON-массив формата wireturn (Throne: turnable + wgConfig).
enum ProfileParser {
    static func parse(text: String) -> [Profile] {
        let decoded = decodeBase64IfNeeded(text)
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)

        var result: [Profile] = parseStructural(trimmed)
        for line in trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let candidate = String(line).trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#") else { continue }
            // Панель мешает форматы в одном ответе: строки-ссылки и строку с полным конфигом
            // sing-box. Именно в такой строке живут mieru и wireguard — в списке ссылок их нет,
            // и раньше они терялись молча.
            if candidate.hasPrefix("{") || candidate.hasPrefix("[") {
                result += parseStructural(candidate)
                continue
            }
            if let profile = parse(link: candidate) {
                result.append(profile)
            }
        }
        return result
    }

    /// «Структурный» ответ: wireturn, turnable или конфиг sing-box целиком.
    private static func parseStructural(_ text: String) -> [Profile] {
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return [] }
        if let profiles = parseWireturn(text), !profiles.isEmpty { return profiles }
        if let profiles = parseTurnable(text), !profiles.isEmpty { return profiles }
        if let profiles = parseSingboxConfig(text), !profiles.isEmpty { return profiles }
        return []
    }

    /// Панели часто отдают список ссылок в base64 (формат v2rayN). Разворачиваем,
    /// если после декодирования появляется схема вида `vless://`.
    static func decodeBase64IfNeeded(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        if compact.contains("://") || compact.hasPrefix("{") || compact.hasPrefix("[") {
            return text
        }
        var normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized += "="
        }
        guard let data = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8),
              decoded.contains("://")
        else { return text }
        return decoded
    }

    /// Бейдж VLESS: протокол + транспорт. Транспорты, которые умеет только Xray,
    /// помечаем явно — иначе непонятно, почему профиль обслуживается другим ядром.
    static func vlessBadge(_ link: VLESSLink) -> String {
        let security = link.security.lowercased()
        switch link.transport {
        case "xhttp":
            return security == "reality" ? "Xray · XHTTP + Reality" : "Xray · XHTTP"
        case "ws":
            return "VLESS · WS"
        case "grpc":
            return "VLESS · gRPC"
        case "h2", "http":
            return "VLESS · HTTP/2"
        case "quic":
            return "VLESS · QUIC"
        default:
            if security == "reality" { return "VLESS · Reality" }
            if security == "tls" { return "VLESS · TLS" }
            return "VLESS"
        }
    }

    static func parse(link: String) -> Profile? {
        let lower = link.lowercased()
        if lower.hasPrefix("vless://") {
            guard let parsed = try? VLESSLink.parse(link) else { return nil }
            // type=xhttp sing-box не умеет — такой профиль запускается ядром Xray.
            let kind: ProfileKind = parsed.transport == "xhttp" ? .xray : .vless
            return Profile(name: parsed.name, kind: kind, payload: link, note: nil,
                           badge: Self.vlessBadge(parsed))
        }
        if lower.hasPrefix("hysteria2://") || lower.hasPrefix("hy2://") {
            guard let parsed = Hysteria2Link.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .hysteria2, payload: link, note: nil)
        }
        if lower.hasPrefix("mierus://") || lower.hasPrefix("mieru://") {
            guard let parsed = MieruLink.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .mieru, payload: link, note: nil)
        }
        if lower.hasPrefix("amneziawg://") || lower.hasPrefix("wg://") {
            guard let parsed = WireGuardConfig.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .wireguard, payload: link, note: parsed.note)
        }
        return nil
    }

    /// Что именно пришло от панели — для журнала импорта. Без этого «добавлено 5 профилей»
    /// не отличить от «панель отдала другой формат».
    static func describe(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "пустой ответ" }
        if trimmed.hasPrefix("<") {
            return "HTML (\(trimmed.count) символов) — страница вместо подписки"
        }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let config = object as? [String: Any] {
                let outbounds = (config["outbounds"] as? [[String: Any]] ?? [])
                    .compactMap { $0["type"] as? String }
                let endpoints = (config["endpoints"] as? [[String: Any]] ?? [])
                    .compactMap { $0["type"] as? String }
                return "sing-box JSON: outbounds [\(outbounds.joined(separator: ", "))], endpoints [\(endpoints.joined(separator: ", "))]"
            }
            if let array = object as? [Any] {
                return "JSON-массив: \(array.count) элементов"
            }
        }

        // Смешанный ответ: строки-ссылки плюс строка с JSON-конфигом (так отдаёт эта панель).
        let lines = trimmed
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let jsonLines = lines.filter { $0.hasPrefix("{") || $0.hasPrefix("[") }
        if !jsonLines.isEmpty {
            var counts: [String: Int] = [:]
            for line in lines where !jsonLines.contains(line) {
                if let schemeEnd = line.range(of: "://") {
                    counts[String(line[..<schemeEnd.lowerBound]), default: 0] += 1
                }
            }
            let links = counts.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            let payloads = jsonLines.map { describe($0) }.joined(separator: " + ")
            return "смешанный ответ: ссылки [\(links.isEmpty ? "нет" : links)] + \(payloads)"
        }

        var base64 = trimmed
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        if base64.count > 16,
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let decoded = String(data: data, encoding: .utf8),
           decoded.contains("://") {
            var counts: [String: Int] = [:]
            for line in decoded.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                guard let schemeEnd = line.range(of: "://") else { continue }
                let scheme = String(line[..<schemeEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard !scheme.isEmpty else { continue }
                counts[scheme, default: 0] += 1
            }
            let summary = counts.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            let total = counts.values.reduce(0, +)
            return "base64-список: \(total) ссылок (\(summary))"
        }

        return "неизвестный формат (\(trimmed.count) символов)"
    }

    /// Полноценный конфиг sing-box (панель отдаёт его на «клиентский» User-Agent).
    ///
    /// Из него достаём не один профиль, а все: по одному на каждый outbound (vless/hysteria2/mieru/…)
    /// и на каждый endpoint (wireguard), плюс отдельный профиль «как есть» с urltest/selector.
    /// Именно так в подписку попадают Mieru и WireGuard — в v2ray-списке их нет.
    static func parseSingboxConfig(_ text: String) -> [Profile]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any],
              let outbounds = config["outbounds"] as? [[String: Any]],
              !outbounds.isEmpty
        else { return nil }

        var profiles: [Profile] = []
        let inbound: [String: Any] = [
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": ConfigBuilder.listenPort,
        ]

        for outbound in outbounds {
            guard let type = outbound["type"] as? String,
                  let tag = outbound["tag"] as? String,
                  outbound["server"] != nil
            else { continue }
            let mini: [String: Any] = [
                "log": ["level": "info", "timestamp": true],
                "inbounds": [inbound],
                "outbounds": [outbound],
                "route": ["final": tag],
            ]
            guard let json = encode(mini) else { continue }
            profiles.append(Profile(
                name: tag,
                kind: .custom,
                payload: json,
                note: nil,
                badge: Self.protocolTitle(type)
            ))
        }

        if let endpoints = config["endpoints"] as? [[String: Any]] {
            for endpoint in endpoints {
                guard let type = endpoint["type"] as? String,
                      let tag = endpoint["tag"] as? String
                else { continue }
                let mini: [String: Any] = [
                    "log": ["level": "info", "timestamp": true],
                    "inbounds": [inbound],
                    "endpoints": [endpoint],
                    "route": ["final": tag],
                ]
                guard let json = encode(mini) else { continue }
                let amnezia = endpoint["amnezia_wg"] as? [String: Any] ?? [:]
                let dropped = amnezia.keys
                    .filter { !WireGuardConfig.knownAmneziaFields.contains($0) }
                    .sorted()
                profiles.append(Profile(
                    name: tag,
                    kind: .custom,
                    payload: json,
                    note: dropped.isEmpty
                        ? nil
                        : "AWG 3.x: поля \(dropped.joined(separator: ", ")) ядру неизвестны и отбрасываются",
                    badge: Self.protocolTitle(type)
                ))
            }
        }

        return profiles
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func protocolTitle(_ type: String) -> String {
        switch type {
        case "vless": return "VLESS"
        case "hysteria2": return "Hysteria2"
        case "mieru": return "Mieru"
        case "wireguard": return "WireGuard"
        case "tuic": return "TUIC"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "anytls": return "AnyTLS"
        case "ssh": return "SSH"
        case "hysteria": return "Hysteria"
        default: return type
        }
    }

    // MARK: - wireturn (Throne)
    /// Формат `?format=turnable`: массив конфигов клиента Turnable.
    /// Движка в сборке нет, поэтому профили добавляются только для наглядности.
    static func parseTurnable(_ text: String) -> [Profile]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]]
        else { return nil }

        var profiles: [Profile] = []
        for item in array {
            guard item["platform_id"] != nil, item["call_id"] != nil else { continue }
            guard let encoded = try? JSONSerialization.data(withJSONObject: item),
                  let json = String(data: encoded, encoding: .utf8)
            else { continue }
            let name = (item["name"] as? String) ?? "turnable"
            // В формате turnable панель отдаёт только описание транспорта (gateway, call_id,
            // pub_key, routes): ни ключей WireGuard, ни адреса в туннеле здесь нет.
            // Turnable — транспортный профиль: запускает VK-авторизацию и SRTP-сессию.
            // Это его штатный режим, поэтому никаких «ограничено» в списке.
            profiles.append(Profile(name: name, kind: .turnable, payload: json, note: nil))
        }
        return profiles
    }

    /// Формат: массив объектов `{kernelConfig:{type:"turnable",config:{…}}, wgConfig:{…}}`.
    /// Из него собирается цепочка «WireGuard → локальный порт Turnable → WARP».
    static func parseWireturn(_ text: String) -> [Profile]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]]
        else { return nil }

        var profiles: [Profile] = []
        for item in array {
            let name = (item["name"] as? String) ?? "wireturn"
            guard let kernel = item["kernelConfig"] as? [String: Any],
                  let config = kernel["config"] as? [String: Any],
                  let wg = item["wgConfig"] as? [String: Any]
            else { continue }

            var payload: [String: Any] = ["kernel": config, "wg": wg]
            if let vless = item["vlessConfig"] as? [String: Any] { payload["vless"] = vless }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { continue }

            profiles.append(Profile(
                name: name,
                kind: .wireturn,
                payload: json,
                note: nil
            ))
        }
        return profiles
    }
}

// MARK: - Разбор authority

/// Ручной разбор ссылки: `URLComponents` не принимает порт вида `56096-56121`,
/// а панели отдают именно диапазоны, поэтому authority режем сами.
struct LinkParts {
    let user: String
    let password: String
    let host: String
    let portText: String
    let query: [String: String]
    let fragment: String?

    var firstPort: Int? {
        Int(portText.split(separator: "-").first.map(String.init) ?? "")
    }

    var portRange: String? {
        portText.contains("-") ? portText : nil
    }

    static func parse(_ raw: String) -> LinkParts? {
        guard let schemeRange = raw.range(of: "://") else { return nil }
        var rest = String(raw[schemeRange.upperBound...])

        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[..<hash])
        }

        var query: [String: String] = [:]
        if let question = rest.firstIndex(of: "?") {
            let queryText = String(rest[rest.index(after: question)...])
            rest = String(rest[..<question])
            for pair in queryText.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).lowercased()
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                query[key] = value
            }
        }

        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }

        var user = ""
        var password = ""
        if let at = rest.lastIndex(of: "@") {
            let auth = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            if let colon = auth.firstIndex(of: ":") {
                user = String(auth[..<colon]).removingPercentEncoding ?? String(auth[..<colon])
                password = String(auth[auth.index(after: colon)...]).removingPercentEncoding
                    ?? String(auth[auth.index(after: colon)...])
            } else {
                user = auth
            }
        }

        var host = rest
        var portText = ""
        if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            portText = String(rest[rest.index(after: colon)...])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        guard !host.isEmpty else { return nil }
        return LinkParts(user: user, password: password, host: host,
                         portText: portText, query: query, fragment: fragment)
    }
}

// MARK: - Hysteria2

struct Hysteria2Link {
    let name: String
    let host: String
    let port: Int
    let portRange: String?
    let password: String
    let serverName: String?
    let alpn: [String]
    let obfsType: String?
    let obfsPassword: String?
    let hopInterval: String?
    let insecure: Bool

    static func parse(_ raw: String) -> Hysteria2Link? {
        // Порт в ссылке бывает диапазоном (`56096-56121`), поэтому разбираем authority сами.
        guard let parts = LinkParts.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let port = parts.firstPort
        else { return nil }

        // В ссылке user:pass, а sing-box ждёт одну строку "user:pass" (см. документацию
        // по hysteria2: userpass-аутентификация не поддерживается отдельно).
        let password = parts.password.isEmpty ? parts.user : "\(parts.user):\(parts.password)"

        let name = parts.fragment ?? "\(parts.host):\(port)"
        let portRange = parts.portRange ?? parts.query["mport"] ?? parts.query["ports"]

        return Hysteria2Link(
            name: name,
            host: parts.host,
            port: port,
            portRange: portRange,
            password: password,
            serverName: parts.query["sni"],
            alpn: (parts.query["alpn"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
            obfsType: parts.query["obfs"],
            obfsPassword: parts.query["obfs-password"],
            hopInterval: parts.query["hop_interval"],
            insecure: (parts.query["insecure"] ?? "") == "1" || (parts.query["allowinsecure"] ?? "") == "1"
        )
    }
}

// MARK: - Mieru

struct MieruLink {
    let name: String
    let host: String
    let port: Int
    let portRange: String?
    let userName: String
    let password: String
    let transport: String
    let multiplexing: String?

    static func parse(_ raw: String) -> MieruLink? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host
        else { return nil }

        // В ссылке бывает два параметра port: отдельный и диапазон.
        var ports: [String] = []
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let key = item.name.lowercased()
            if key == "port", let value = item.value {
                ports.append(value)
            } else if let value = item.value {
                query[key] = value
            }
        }
        guard let first = ports.first, let port = Int(first) else { return nil }

        let userName = components.user ?? ""
        let password = components.password ?? ""
        let name = components.fragment?.removingPercentEncoding ?? "\(host):\(port)"

        return MieruLink(
            name: name,
            host: host,
            port: port,
            portRange: ports.count > 1 ? ports[1] : nil,
            userName: userName,
            password: password,
            transport: (query["protocol"] ?? "TCP").uppercased(),
            multiplexing: query["multiplexing"]
        )
    }
}

// MARK: - WireGuard

struct WireGuardLink {
    let name: String
    let host: String
    let port: Int
    let privateKey: String
    let publicKey: String
    let addresses: [String]
    let mtu: Int
    let keepAlive: Int
    let amnezia: Bool
    let note: String?

    static func parse(_ raw: String) -> WireGuardLink? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, let port = components.port
        else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }
        guard let privateKey = query["private_key"],
              let publicKey = query["public_key"]
        else { return nil }

        let addresses = (query["local_address"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let amnezia = (query["enable_amnezia"] ?? "") == "true"
        let name = components.fragment?.removingPercentEncoding ?? "\(host):\(port)"

        return WireGuardLink(
            name: name,
            host: host,
            port: port,
            privateKey: privateKey,
            publicKey: publicKey,
            addresses: addresses,
            mtu: Int(query["mtu"] ?? "") ?? 1280,
            keepAlive: Int(query["persistent_keepalive_interval"] ?? "") ?? 25,
            amnezia: amnezia,
            note: amnezia
                ? "AmneziaWG 3.1: sing-box не умеет обфускацию s1/s2/h1–h4/i1 — как обычный WireGuard к этому серверу не подключиться, нужен движок amneziawg-go"
                : nil
        )
    }
}

import Foundation

/// Разбор всего, что может лежать в подписке: по одной share-ссылке на строку,
/// либо JSON-массив формата wireturn (Throne: turnable + wgConfig).
enum ProfileParser {
    static func parse(text: String) -> [Profile] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            if let profiles = parseWireturn(trimmed), !profiles.isEmpty {
                return profiles
            }
        }
        var result: [Profile] = []
        for line in trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let candidate = String(line).trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#") else { continue }
            if let profile = parse(link: candidate) {
                result.append(profile)
            }
        }
        return result
    }

    static func parse(link: String) -> Profile? {
        let lower = link.lowercased()
        if lower.hasPrefix("vless://") {
            guard let parsed = try? VLESSLink.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .vless, payload: link, note: nil)
        }
        if lower.hasPrefix("hysteria2://") || lower.hasPrefix("hy2://") {
            guard let parsed = Hysteria2Link.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .hysteria2, payload: link, note: nil)
        }
        if lower.hasPrefix("mierus://") || lower.hasPrefix("mieru://") {
            guard let parsed = MieruLink.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .mieru, payload: link, note: nil)
        }
        if lower.hasPrefix("wg://") {
            guard let parsed = WireGuardLink.parse(link) else { return nil }
            return Profile(name: parsed.name, kind: .wireguard, payload: link, note: parsed.note)
        }
        return nil
    }

    // MARK: - wireturn (Throne)

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
                note: "движок Turnable в этой сборке не встроен — цепочка не поднимется"
            ))
        }
        return profiles
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
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, let port = components.port
        else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }

        // В ссылке user:pass, а sing-box ждёт одну строку "user:pass" (см. документацию
        // по hysteria2: userpass-аутентификация не поддерживается отдельно).
        let user = components.user ?? ""
        let secret = components.password ?? ""
        let password = secret.isEmpty ? user : "\(user):\(secret)"

        let name = components.fragment?.removingPercentEncoding ?? "\(host):\(port)"
        let portRange = query["mport"] ?? query["ports"]

        return Hysteria2Link(
            name: name,
            host: host,
            port: port,
            portRange: portRange,
            password: password,
            serverName: query["sni"],
            alpn: (query["alpn"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
            obfsType: query["obfs"],
            obfsPassword: query["obfs-password"],
            hopInterval: query["hop_interval"],
            insecure: (query["insecure"] ?? "") == "1" || (query["allowinsecure"] ?? "") == "1"
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
            note: amnezia ? "AmneziaWG (s1/s2/h1–h4/i1) требует отдельного движка; здесь будет обычный WireGuard" : nil
        )
    }
}

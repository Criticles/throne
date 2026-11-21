import Foundation

/// WireGuard / AmneziaWG из подписки: две формы записи.
///
/// 1. `wg://host:port?private_key=…&public_key=…&enable_amnezia=true&s1=37&h1=…`
/// 2. `amneziawg://<base64 от wg-quick INI>` — так отдаёт панель клиенту YPtun.
///
/// Оба варианта сводятся к одному endpoint-у sing-box: `type: wireguard` + вложенный
/// `amnezia_wg`. Ядро форка Трона умеет AmneziaWG нативно (`option.AmneziaWGOptions`),
/// поэтому отдельный движок не нужен.
struct WireGuardConfig {
    let name: String
    let privateKey: String
    let addresses: [String]
    let mtu: Int
    let keepAlive: Int
    let publicKey: String
    let host: String
    let port: Int
    /// Готовый словарь для `amnezia_wg` (только поля, известные ядру).
    let amnezia: [String: Any]?
    let note: String?
    /// Ключи, которые панель прислала, а ядро не знает (random_trailers / disable_cookies).
    let droppedFields: [String]

    /// Поля, которые понимает `option.AmneziaWGOptions` в форке.
    static let knownAmneziaFields: Set<String> = [
        "jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
        "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
        "header_protection_key", "content_padding_addition", "rekey_after_time",
        "rekey_timeout", "reject_after_time", "keepalive_timeout", "max_handshake_attempts",
        // AmneziaWG 3.1 (есть в ядре начиная с коммита 183cf759 — то, что использует Throne PC).
        "random_trailers", "disable_cookies",
    ]

    static func parse(_ raw: String) -> WireGuardConfig? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("amneziawg://") {
            return parseQuic(trimmed)
        }
        return parseURL(trimmed)
    }

    // MARK: - amneziawg:// (base64 wg-quick)

    private static func parseQuic(_ raw: String) -> WireGuardConfig? {
        guard let schemeRange = raw.range(of: "://") else { return nil }
        var payload = String(raw[schemeRange.upperBound...])

        var name = "AmneziaWG"
        if let hash = payload.firstIndex(of: "#") {
            name = String(payload[payload.index(after: hash)...]).removingPercentEncoding ?? name
            payload = String(payload[..<hash])
        }

        var base64 = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedPercent = base64.removingPercentEncoding {
            base64 = decodedPercent
        }
        base64 = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let ini = String(data: data, encoding: .utf8)
        else { return nil }

        var values: [String: String] = [:]
        for line in ini.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("[") else { continue }
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        guard let privateKey = values["privatekey"],
              let publicKey = values["publickey"],
              let endpoint = values["endpoint"]
        else { return nil }

        let endpointParts = endpoint.split(separator: ":")
        guard endpointParts.count == 2, let port = Int(endpointParts[1]) else { return nil }

        let addresses = (values["address"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var amnezia: [String: Any] = [:]
        let dropped: [String] = []
        for (key, value) in values {
            switch key {
            case "jc", "jmin", "jmax", "s1", "s2", "s3", "s4":
                if let number = Int(value), number != 0 { amnezia[key] = number }
            case "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5":
                if !value.isEmpty { amnezia[key] = value }
            case "randomtrailers":
                if value != "0" && !value.isEmpty { amnezia["random_trailers"] = true }
            case "disablecookies":
                if value != "0" && !value.isEmpty { amnezia["disable_cookies"] = true }
            default:
                break
            }
        }

        return WireGuardConfig(
            name: name,
            privateKey: privateKey,
            addresses: addresses,
            mtu: Int(values["mtu"] ?? "") ?? 1280,
            keepAlive: Int(values["persistentkeepalive"] ?? "") ?? 25,
            publicKey: publicKey,
            host: String(endpointParts[0]),
            port: port,
            amnezia: amnezia.isEmpty ? nil : amnezia,
            note: dropped.isEmpty ? nil : "ядро не знает AWG-поля \(dropped.joined(separator: ", ")) — они отброшены",
            droppedFields: dropped
        )
    }

    // MARK: - wg://

    private static func parseURL(_ raw: String) -> WireGuardConfig? {
        guard let components = URLComponents(string: raw),
              let host = components.host, let port = components.port
        else { return nil }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }
        guard let privateKey = query["private_key"], let publicKey = query["public_key"] else {
            return nil
        }

        let addresses = (query["local_address"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var amnezia: [String: Any] = [:]
        for (key, value) in query {
            switch key {
            case "s1", "s2", "s3", "s4", "jc", "jmin", "jmax":
                if let number = Int(value), number != 0 { amnezia[key] = number }
            case "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5":
                if !value.isEmpty { amnezia[key] = value }
            default:
                break
            }
        }

        let name = components.fragment?.removingPercentEncoding ?? "\(host):\(port)"
        return WireGuardConfig(
            name: name,
            privateKey: privateKey,
            addresses: addresses,
            mtu: Int(query["mtu"] ?? "") ?? 1280,
            keepAlive: Int(query["persistent_keepalive_interval"] ?? "") ?? 25,
            publicKey: publicKey,
            host: host,
            port: port,
            amnezia: amnezia.isEmpty ? nil : amnezia,
            note: nil,
            droppedFields: []
        )
    }
}

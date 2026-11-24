import Foundation

/// Разбор ссылки/JSON профиля в человекочитаемые настройки — для экрана «Сведения».
/// Секреты (UUID, пароли) не показываем, только то, что помогает понять сервер.
enum ServerInfo {
    static func rows(for profile: Profile) -> [(String, String)] {
        let payload = profile.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("{") {
            return jsonRows(payload, kind: profile.kind)
        }
        return linkRows(payload)
    }

    private static func linkRows(_ payload: String) -> [(String, String)] {
        var rows: [(String, String)] = []
        guard let schemeEnd = payload.range(of: "://") else { return rows }
        let scheme = String(payload[..<schemeEnd.lowerBound]).lowercased()
        rows.append(("Протокол", scheme.uppercased()))

        var rest = String(payload[schemeEnd.upperBound...])
        var fragment = ""
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        var query = ""
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
        }
        if let at = rest.lastIndex(of: "@") {
            rest = String(rest[rest.index(after: at)...])
        }
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }
        let parts = rest.split(separator: ":")
        if parts.count >= 2 {
            rows.append(("Хост", String(parts[0])))
            rows.append(("Порт", String(parts[1])))
        } else if let first = parts.first {
            rows.append(("Хост", String(first)))
        }
        if !fragment.isEmpty {
            rows.append(("Имя в ссылке", fragment.removingPercentEncoding ?? fragment))
        }

        for pair in query.split(separator: "&") {
            let item = pair.split(separator: "=", maxSplits: 1)
            guard item.count == 2 else { continue }
            let key = String(item[0]).lowercased()
            let value = String(item[1]).removingPercentEncoding ?? String(item[1])
            switch key {
            case "security": rows.append(("Безопасность", value.uppercased()))
            case "sni": rows.append(("SNI", value))
            case "type": rows.append(("Транспорт", value))
            case "flow": rows.append(("Flow", value))
            case "alpn": rows.append(("ALPN", value))
            case "path": rows.append(("Путь", value))
            case "host": rows.append(("Заголовок Host", value))
            case "obfs": rows.append(("Obfs", value))
            case "mode": rows.append(("Режим", value))
            default: break
            }
        }
        return rows
    }

    private static func jsonRows(_ payload: String, kind: ProfileKind) -> [(String, String)] {
        var rows: [(String, String)] = [("Формат", kind.title)]
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any]
        else { return rows }

        if let wg = root["wg"] as? [String: Any] {
            if let endpoint = wg["endpoint"] as? String { rows.append(("WG-эндпоинт", endpoint)) }
            if let address = wg["address"] as? String { rows.append(("Адрес", address)) }
            if let mtu = wg["mtu"] as? String { rows.append(("MTU", mtu)) }
            if let keepalive = wg["persistentKeepalive"] as? String {
                rows.append(("Keepalive", keepalive))
            }
        }
        if let kernel = root["kernel"] as? [String: Any] {
            if let gateway = kernel["turn_server"] as? String { rows.append(("TURN", gateway)) }
            if let proto = kernel["proto"] as? String { rows.append(("Транспорт TURN", proto)) }
            if let platform = kernel["platform_id"] as? String { rows.append(("Платформа", platform)) }
            if let routes = kernel["routes"] as? [[String: Any]],
               let first = routes.first,
               let id = first["id"] as? String {
                rows.append(("Маршрут", id))
            }
        }
        if let outbounds = root["outbounds"] as? [[String: Any]],
           let first = outbounds.first {
            if let server = first["server"] as? String { rows.append(("Хост", server)) }
            if let port = first["server_port"] as? Int { rows.append(("Порт", String(port))) }
            if let type = first["type"] as? String { rows.append(("Тип", type)) }
        }
        if let endpoints = root["endpoints"] as? [[String: Any]],
           let peers = endpoints.first?["peers"] as? [[String: Any]],
           let peer = peers.first {
            if let address = peer["address"] as? String { rows.append(("Пир", address)) }
            if let port = peer["port"] as? Int { rows.append(("Порт", String(port))) }
        }
        return rows
    }
}

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
           let endpoint = endpoints.first {
            if let type = endpoint["type"] as? String { rows.append(("Тип", type)) }
            if let tag = endpoint["tag"] as? String { rows.append(("Тег", tag)) }
            if let mtu = endpoint["mtu"] as? Int { rows.append(("MTU", String(mtu))) }
            if let addresses = endpoint["address"] as? [String], !addresses.isEmpty {
                rows.append(("Адрес", addresses.joined(separator: ", ")))
            }
            if let peers = endpoint["peers"] as? [[String: Any]], let peer = peers.first {
                if let address = peer["address"] as? String { rows.append(("Пир", address)) }
                if let port = peer["port"] as? Int { rows.append(("Порт", String(port))) }
                if let key = peer["public_key"] as? String {
                    rows.append(("Публичный ключ", mask(key)))
                }
                if let psk = peer["pre_shared_key"] as? String, !psk.isEmpty {
                    rows.append(("Preshared key", mask(psk)))
                }
                if let allowed = peer["allowed_ips"] as? [String], !allowed.isEmpty {
                    rows.append(("Allowed IPs", allowed.joined(separator: ", ")))
                }
                if let keepalive = peer["persistent_keepalive_interval"] {
                    rows.append(("Keepalive", String(describing: keepalive)))
                }
                if let reserved = peer["reserved"] as? [Int], !reserved.isEmpty {
                    rows.append(("Reserved", reserved.map(String.init).joined(separator: " ")))
                }
            }
            // AmneziaWG: обфускация живёт отдельным словарём у эндпоинта.
            if let privateKey = endpoint["private_key"] as? String {
                rows.append(("Приватный ключ", mask(privateKey)))
            }
            // В конфиге ядра обфускация лежит в `amnezia_wg`, в старых — в `amnezia`.
            if let awg = (endpoint["amnezia_wg"] ?? endpoint["amnezia"]) as? [String: Any] {
                for key in ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"] {
                    if let value = awg[key] { rows.append((key.uppercased(), String(describing: value))) }
                }
                for key in ["h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"] {
                    if let value = awg[key] { rows.append((key.uppercased(), String(describing: value))) }
                }
                if let flag = awg["random_trailers"], String(describing: flag) == "1" {
                    rows.append(("Random trailers", "вкл"))
                }
                if let flag = awg["disable_cookies"], String(describing: flag) == "1" {
                    rows.append(("Disable cookies", "вкл"))
                }
            }
        }

        // VLESS/Reality и прочее: что реально влияет на подключение.
        if let outbounds = root["outbounds"] as? [[String: Any]], let first = outbounds.first {
            if let uuid = first["uuid"] as? String { rows.append(("UUID", mask(uuid))) }
            if let flow = first["flow"] as? String, !flow.isEmpty { rows.append(("Flow", flow)) }
            if let method = first["method"] as? String { rows.append(("Метод", method)) }
            if let password = first["password"] as? String { rows.append(("Пароль", mask(password))) }
            if let obfs = first["obfs"] as? [String: Any] {
                if let type = obfs["type"] as? String { rows.append(("Obfs", type)) }
                if let password = obfs["password"] as? String { rows.append(("Obfs-пароль", mask(password))) }
            }
            if let tls = first["tls"] as? [String: Any] {
                if let enabled = tls["enabled"] as? Bool {
                    rows.append(("TLS", enabled ? "вкл" : "выкл"))
                }
                if let sni = tls["server_name"] as? String, !sni.isEmpty { rows.append(("SNI", sni)) }
                if let insecure = tls["insecure"] as? Bool, insecure {
                    rows.append(("Проверка сертификата", "отключена"))
                }
                if let alpn = tls["alpn"] as? [String], !alpn.isEmpty {
                    rows.append(("ALPN", alpn.joined(separator: ", ")))
                }
                if let utls = tls["utls"] as? [String: Any],
                   let fingerprint = utls["fingerprint"] as? String {
                    rows.append(("uTLS", fingerprint))
                }
                if let reality = tls["reality"] as? [String: Any] {
                    if let key = reality["public_key"] as? String {
                        rows.append(("Reality public key", mask(key)))
                    }
                    if let short = reality["short_id"] as? String, !short.isEmpty {
                        rows.append(("Reality short id", short))
                    }
                }
            }
            if let transport = first["transport"] as? [String: Any] {
                if let type = transport["type"] as? String { rows.append(("Транспорт", type)) }
                if let path = transport["path"] as? String, !path.isEmpty {
                    rows.append(("Путь", path))
                }
                if let service = transport["service_name"] as? String, !service.isEmpty {
                    rows.append(("Service name", service))
                }
            }
        }
        return rows
    }

    /// Секреты не печатаем целиком: первых и последних символов хватает,
    /// чтобы сверить ключ, но скопировать его с экрана нельзя.
    private static func mask(_ value: String) -> String {
        guard value.count > 10 else { return String(repeating: "•", count: max(value.count, 3)) }
        return value.prefix(4) + "…" + value.suffix(3)
    }
}

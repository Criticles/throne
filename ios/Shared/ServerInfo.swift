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

    /// Ссылки разбираем теми же парсерами, что и импорт: тогда «Сведения»
    /// показывают ровно то, с чем пойдёт ядро, а не догадки по строке.
    private static func linkRows(_ payload: String) -> [(String, String)] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return [] }
        let scheme = String(trimmed[..<schemeEnd.lowerBound]).lowercased()
        switch scheme {
        case "vless": return vlessRows(trimmed)
        case "vmess": return vmessRows(trimmed)
        case "trojan": return trojanRows(trimmed)
        case "ss": return shadowsocksRows(trimmed)
        case "tuic": return tuicRows(trimmed)
        case "masterdns": return masterdnsRows(trimmed)
        case "hysteria2", "hy2": return hysteriaRows(trimmed)
        case "mieru", "mierus": return mieruRows(trimmed)
        case "amneziawg", "wg": return wireguardRows(trimmed)
        default: return genericRows(trimmed, scheme: scheme)
        }
    }

    private static func vlessRows(_ link: String) -> [(String, String)] {
        guard let parsed = try? VLESSLink.parse(link) else { return genericRows(link, scheme: "vless") }
        var rows: [(String, String)] = []
        rows.append(("Протокол", parsed.transport == "xhttp" ? "VLESS XHTTP (Xray)" : "VLESS"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        rows.append(("UUID", mask(parsed.uuid)))
        if let flow = parsed.flow, !flow.isEmpty { rows.append(("Flow", flow)) }
        rows.append(("Безопасность", parsed.security.uppercased()))
        if let sni = parsed.serverName, !sni.isEmpty { rows.append(("SNI", sni)) }
        if let fingerprint = parsed.fingerprint, !fingerprint.isEmpty {
            rows.append(("uTLS", fingerprint))
        }
        if let key = parsed.publicKey, !key.isEmpty {
            rows.append(("Reality public key", mask(key)))
        }
        if let short = parsed.shortID, !short.isEmpty { rows.append(("Reality short id", short)) }
        rows.append(("Транспорт", parsed.transport))
        if let path = parsed.path, !path.isEmpty { rows.append(("Путь", path)) }
        if let host = parsed.hostHeader, !host.isEmpty { rows.append(("Заголовок Host", host)) }
        if let mode = parsed.mode, !mode.isEmpty { rows.append(("Режим", mode)) }
        if !parsed.alpn.isEmpty { rows.append(("ALPN", parsed.alpn.joined(separator: ", "))) }
        if let encoding = parsed.packetEncoding, !encoding.isEmpty {
            rows.append(("Packet encoding", encoding))
        }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func vmessRows(_ link: String) -> [(String, String)] {
        guard let parsed = VMessLink.parse(link) else { return genericRows(link, scheme: "vmess") }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "VMess"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        rows.append(("UUID", mask(parsed.uuid)))
        rows.append(("Шифрование", parsed.security))
        rows.append(("Alter ID", String(parsed.alterID)))
        rows.append(("Транспорт", parsed.network ?? "tcp"))
        if let path = parsed.path, !path.isEmpty { rows.append(("Путь", path)) }
        if let host = parsed.hostHeader, !host.isEmpty { rows.append(("Заголовок Host", host)) }
        rows.append(("TLS", parsed.tlsEnabled ? "вкл" : "выкл"))
        if let sni = parsed.serverName, !sni.isEmpty { rows.append(("SNI", sni)) }
        if !parsed.alpn.isEmpty { rows.append(("ALPN", parsed.alpn.joined(separator: ", "))) }
        if let fp = parsed.fingerprint, !fp.isEmpty { rows.append(("uTLS", fp)) }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func trojanRows(_ link: String) -> [(String, String)] {
        guard let parsed = TrojanLink.parse(link) else { return genericRows(link, scheme: "trojan") }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "Trojan"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        rows.append(("Пароль", mask(parsed.password)))
        if let sni = parsed.serverName, !sni.isEmpty { rows.append(("SNI", sni)) }
        if !parsed.alpn.isEmpty { rows.append(("ALPN", parsed.alpn.joined(separator: ", "))) }
        if let fp = parsed.fingerprint, !fp.isEmpty { rows.append(("uTLS", fp)) }
        rows.append(("Проверка сертификата", parsed.insecure ? "отключена" : "включена"))
        rows.append(("Транспорт", parsed.transport ?? "tcp"))
        if let path = parsed.path, !path.isEmpty { rows.append(("Путь", path)) }
        if let host = parsed.hostHeader, !host.isEmpty { rows.append(("Заголовок Host", host)) }
        if let service = parsed.serviceName, !service.isEmpty {
            rows.append(("Service name", service))
        }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func shadowsocksRows(_ link: String) -> [(String, String)] {
        guard let parsed = ShadowsocksLink.parse(link) else {
            return genericRows(link, scheme: "ss")
        }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "Shadowsocks"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        rows.append(("Метод", parsed.method))
        rows.append(("Пароль", mask(parsed.password)))
        if let plugin = parsed.plugin, !plugin.isEmpty {
            rows.append(("Плагин", plugin))
            if let options = parsed.pluginOpts, !options.isEmpty {
                rows.append(("Опции плагина", options))
            }
        }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func tuicRows(_ link: String) -> [(String, String)] {
        guard let parsed = TUICLink.parse(link) else { return genericRows(link, scheme: "tuic") }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "TUIC"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        rows.append(("UUID", mask(parsed.uuid)))
        rows.append(("Пароль", mask(parsed.password)))
        rows.append(("Контроль перегрузки", parsed.congestionControl))
        rows.append(("Режим UDP", parsed.udpRelayMode))
        if let sni = parsed.serverName, !sni.isEmpty { rows.append(("SNI", sni)) }
        rows.append(("ALPN", parsed.alpn.joined(separator: ", ")))
        rows.append(("Проверка сертификата", parsed.insecure ? "отключена" : "включена"))
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func masterdnsRows(_ link: String) -> [(String, String)] {
        guard let parsed = MasterDNSLink.parse(link) else {
            return genericRows(link, scheme: "masterdns")
        }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "MasterDNS"))
        rows.append(("Домены", parsed.domains.joined(separator: ", ")))
        rows.append(("Шифрование", parsed.encryptionMethod))
        if !parsed.encryptionKey.isEmpty {
            rows.append(("Ключ", mask(parsed.encryptionKey)))
        }
        rows.append(("Режим", parsed.mode))
        if !parsed.resolvers.isEmpty {
            rows.append(("Резолверы", parsed.resolvers.joined(separator: ", ")))
        }
        if let balancing = parsed.balancing { rows.append(("Балансировка", balancing)) }
        if let duplication = parsed.duplication {
            rows.append(("Дублирование пакетов", String(duplication)))
        }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func hysteriaRows(_ link: String) -> [(String, String)] {
        guard let parsed = Hysteria2Link.parse(link) else {
            return genericRows(link, scheme: "hysteria2")
        }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "Hysteria2"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        if let range = parsed.portRange { rows.append(("Диапазон портов", range)) }
        rows.append(("Пароль", mask(parsed.password)))
        if let sni = parsed.serverName, !sni.isEmpty { rows.append(("SNI", sni)) }
        if !parsed.alpn.isEmpty { rows.append(("ALPN", parsed.alpn.joined(separator: ", "))) }
        if let obfs = parsed.obfsType, !obfs.isEmpty { rows.append(("Obfs", obfs)) }
        if let password = parsed.obfsPassword, !password.isEmpty {
            rows.append(("Obfs-пароль", mask(password)))
        }
        if let hop = parsed.hopInterval, !hop.isEmpty { rows.append(("Смена портов", hop)) }
        rows.append(("Проверка сертификата", parsed.insecure ? "отключена" : "включена"))
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func mieruRows(_ link: String) -> [(String, String)] {
        guard let parsed = MieruLink.parse(link) else { return genericRows(link, scheme: "mieru") }
        var rows: [(String, String)] = []
        rows.append(("Протокол", "Mieru"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        if let range = parsed.portRange { rows.append(("Диапазон портов", range)) }
        rows.append(("Пользователь", parsed.userName))
        rows.append(("Пароль", mask(parsed.password)))
        rows.append(("Транспорт", parsed.transport))
        if let multiplexing = parsed.multiplexing, !multiplexing.isEmpty {
            rows.append(("Мультиплексирование", multiplexing.uppercased()))
        }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    private static func wireguardRows(_ link: String) -> [(String, String)] {
        guard let parsed = WireGuardConfig.parse(link) else {
            return genericRows(link, scheme: "wireguard")
        }
        var rows: [(String, String)] = []
        rows.append(("Протокол", parsed.amnezia == nil ? "WireGuard" : "AmneziaWG"))
        rows.append(("Хост", parsed.host))
        rows.append(("Порт", String(parsed.port)))
        if !parsed.addresses.isEmpty {
            rows.append(("Адрес", parsed.addresses.joined(separator: ", ")))
        }
        rows.append(("MTU", String(parsed.mtu)))
        rows.append(("Keepalive", String(parsed.keepAlive)))
        rows.append(("Публичный ключ", mask(parsed.publicKey)))
        rows.append(("Приватный ключ", mask(parsed.privateKey)))
        if let amnezia = parsed.amnezia {
            for key in ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"] {
                if let value = amnezia[key] { rows.append((key.uppercased(), String(describing: value))) }
            }
            for key in ["h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"] {
                if let value = amnezia[key] { rows.append((key.uppercased(), String(describing: value))) }
            }
            if let key = amnezia["header_protection_key"] as? String {
                rows.append(("Header protection", mask(key)))
            }
            for (field, title) in [("content_padding_addition", "Content padding"),
                                   ("rekey_after_time", "Rekey after"),
                                   ("rekey_timeout", "Rekey timeout"),
                                   ("reject_after_time", "Reject after"),
                                   ("keepalive_timeout", "Keepalive timeout"),
                                   ("max_handshake_attempts", "Max handshake attempts")] {
                if let value = amnezia[field] { rows.append((title, String(describing: value))) }
            }
            if (amnezia["random_trailers"] as? Bool) == true { rows.append(("Random trailers", "вкл")) }
            if (amnezia["disable_cookies"] as? Bool) == true { rows.append(("Disable cookies", "вкл")) }
        }
        rows.append(("Имя в ссылке", parsed.name))
        return rows
    }

    /// Неизвестная ссылка: показываем то, что видно без парсера.
    private static func genericRows(_ payload: String, scheme: String) -> [(String, String)] {
        var rows: [(String, String)] = [("Протокол", scheme.uppercased())]
        guard let parts = LinkParts.parse(payload) else { return rows }
        rows.append(("Хост", parts.host))
        if !parts.portText.isEmpty { rows.append(("Порт", parts.portText)) }
        if !parts.user.isEmpty { rows.append(("Пользователь", mask(parts.user))) }
        if !parts.password.isEmpty { rows.append(("Пароль", mask(parts.password))) }
        if let fragment = parts.fragment, !fragment.isEmpty {
            rows.append(("Имя в ссылке", fragment))
        }
        for key in ["sni", "security", "type", "flow", "alpn", "path", "host",
                    "obfs", "mode", "serviceName", "servicename"] {
            if let value = parts.query[key.lowercased()], !value.isEmpty {
                rows.append((key, value))
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

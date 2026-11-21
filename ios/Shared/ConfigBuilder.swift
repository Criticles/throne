import Foundation

/// Сборка конфига sing-box для dev-режима: локальный `mixed`-инбаунд + один профиль наружу.
enum ConfigBuilder {
    /// Локальный SOCKS/HTTP, в который смотрит проверка трафика.
    static let listenPort = 7891
    /// Порт, который слушает Turnable-клиент в подписке wireturn (в wgConfig.endpoint).
    static let wireturnPort = 9000

    enum BuildError: LocalizedError {
        case badPayload(String)
        case unsupported(String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .badPayload(let text): return "не разобрать профиль: \(text)"
            case .unsupported(let text): return text
            case .encodingFailed: return "не удалось собрать конфиг"
            }
        }
    }

    static func build(profile: Profile) throws -> String {
        let config: [String: Any]
        switch profile.kind {
        case .vless:
            let link = try VLESSLink.parse(profile.payload)
            config = try directConfig(outbound: vlessOutbound(link))
        case .hysteria2:
            guard let link = Hysteria2Link.parse(profile.payload) else {
                throw BuildError.badPayload("hysteria2://")
            }
            config = try directConfig(outbound: hysteria2Outbound(link))
        case .mieru:
            guard let link = MieruLink.parse(profile.payload) else {
                throw BuildError.badPayload("mierus://")
            }
            config = try directConfig(outbound: mieruOutbound(link))
        case .wireguard:
            if profile.payload.lowercased().hasPrefix("amneziawg://") {
                throw BuildError.unsupported("AmneziaWG: нужен движок amneziawg-go — в ядре sing-box нет обфускации (S1/S2/H1–H4/I1)")
            }
            guard let link = WireGuardLink.parse(profile.payload) else {
                throw BuildError.badPayload("wg://")
            }
            if link.amnezia {
                // Это не «WireGuard с настройками», а другой протокол: сервер ждёт AWG-обфускацию,
                // и обычный WG-хендшейк ему не подойдёт. Честнее сказать сразу.
                throw BuildError.unsupported(link.note ?? "AmneziaWG требует отдельного движка")
            }
            config = endpointConfig(endpoint: wireguardEndpoint(
                tag: "wg-out",
                privateKey: link.privateKey,
                publicKey: link.publicKey,
                addresses: link.addresses,
                mtu: link.mtu,
                keepAlive: link.keepAlive,
                peerHost: link.host,
                peerPort: link.port
            ))
        case .wireturn:
            config = try wireturnConfig(profile.payload)
        case .turnable:
            throw BuildError.unsupported("движок Turnable в этой сборке не встроен — профиль импортирован, но запустить его нечем")
        case .custom:
            config = try customConfig(profile.payload)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { throw BuildError.encodingFailed }
        return json
    }

    static func note(for profile: Profile) -> String? {
        profile.note
    }

    // MARK: - Обвязка

    private static func inbound() -> [String: Any] {
        [
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": listenPort,
        ]
    }

    private static func directConfig(outbound: [String: Any]) throws -> [String: Any] {
        guard let tag = outbound["tag"] as? String else { throw BuildError.encodingFailed }
        return [
            "log": ["level": "info", "timestamp": true],
            "inbounds": [inbound()],
            "outbounds": [outbound],
            "route": ["final": tag],
        ]
    }

    private static func endpointConfig(endpoint: [String: Any]) -> [String: Any] {
        let tag = (endpoint["tag"] as? String) ?? "wg-out"
        return [
            "log": ["level": "info", "timestamp": true],
            "inbounds": [inbound()],
            "endpoints": [endpoint],
            "route": ["final": tag],
        ]
    }

    // MARK: - Протоколы

    private static func vlessOutbound(_ link: VLESSLink) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": link.host,
            "server_port": link.port,
            "uuid": link.uuid,
        ]
        if let flow = link.flow { outbound["flow"] = flow }
        if let encoding = link.packetEncoding { outbound["packet_encoding"] = encoding }

        switch link.security.lowercased() {
        case "reality":
            var tls: [String: Any] = ["enabled": true, "server_name": link.serverName ?? link.host]
            var reality: [String: Any] = ["enabled": true]
            if let key = link.publicKey { reality["public_key"] = key }
            if let sid = link.shortID { reality["short_id"] = sid }
            tls["reality"] = reality
            if let fingerprint = link.fingerprint {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            outbound["tls"] = tls
        case "tls":
            var tls: [String: Any] = ["enabled": true, "server_name": link.serverName ?? link.host]
            if let fingerprint = link.fingerprint {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            outbound["tls"] = tls
        default:
            break
        }
        return outbound
    }

    private static func hysteria2Outbound(_ link: Hysteria2Link) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "hysteria2",
            "tag": "proxy",
            "server": link.host,
            "server_port": link.port,
            "password": link.password,
        ]

        var tls: [String: Any] = [
            "enabled": true,
            "server_name": link.serverName ?? link.host,
        ]
        if !link.alpn.isEmpty { tls["alpn"] = link.alpn }
        if link.insecure { tls["insecure"] = true }
        outbound["tls"] = tls

        if let obfs = link.obfsType, obfs.lowercased() == "salamander", let password = link.obfsPassword {
            outbound["obfs"] = ["type": "salamander", "password": password]
        }
        if let range = link.portRange {
            outbound["server_ports"] = [range.replacingOccurrences(of: "-", with: ":")]
            if let hop = link.hopInterval { outbound["hop_interval"] = hop }
        }
        return outbound
    }

    private static func mieruOutbound(_ link: MieruLink) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "mieru",
            "tag": "proxy",
            "server": link.host,
            "server_port": link.port,
            "transport": link.transport,
            "username": link.userName,
            "password": link.password,
        ]
        if let range = link.portRange {
            outbound["server_ports"] = [range.replacingOccurrences(of: "-", with: ":")]
        }
        if let multiplexing = link.multiplexing {
            outbound["multiplexing"] = multiplexing
        }
        return outbound
    }

    private static func wireguardEndpoint(
        tag: String,
        privateKey: String,
        publicKey: String,
        addresses: [String],
        mtu: Int,
        keepAlive: Int,
        peerHost: String,
        peerPort: Int
    ) -> [String: Any] {
        [
            "type": "wireguard",
            "tag": tag,
            "system": false,
            "mtu": mtu,
            "address": addresses,
            "private_key": privateKey,
            "peers": [
                [
                    "address": peerHost,
                    "port": peerPort,
                    "public_key": publicKey,
                    "allowed_ips": ["0.0.0.0/0", "::/0"],
                    "persistent_keepalive_interval": keepAlive,
                ]
            ],
        ]
    }

    /// wireturn: WG-эндпоинт смотрит в локальный порт Turnable (в подписке это `127.0.0.1:9000`).
    private static func wireturnConfig(_ payload: String) throws -> [String: Any] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let parsed = object as? [String: Any],
              let wg = parsed["wg"] as? [String: Any]
        else { throw BuildError.badPayload("wireturn JSON") }

        let endpoint = (wg["endpoint"] as? String) ?? "127.0.0.1:\(wireturnPort)"
        let parts = endpoint.split(separator: ":")
        let host = parts.count > 0 ? String(parts[0]) : "127.0.0.1"
        let port = parts.count > 1 ? (Int(parts[1]) ?? wireturnPort) : wireturnPort

        let addresses = (wg["address"] as? String ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let config = endpointConfig(endpoint: wireguardEndpoint(
            tag: "wg-out",
            privateKey: wg["privateKey"] as? String ?? "",
            publicKey: wg["publicKey"] as? String ?? "",
            addresses: addresses,
            mtu: Int(wg["mtu"] as? String ?? "") ?? 1280,
            keepAlive: Int(wg["persistentKeepalive"] as? String ?? "") ?? 25,
            peerHost: host,
            peerPort: port
        ))
        return config
    }

    /// Убирает ключи, которых нет в ядре: панель дописывает `amnezia_wg_*` в wireguard-endpoint,
    /// а sing-box на неизвестном поле отказывается разбирать конфиг целиком.
    private static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dict where !key.hasPrefix("amnezia_wg_") {
                result[key] = sanitize(item)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { sanitize($0) }
        }
        return value
    }

    /// Готовый конфиг sing-box из подписки: подменяем только `inbounds` (TUN в приложении недоступен)
    /// и гарантируем `route.final`, иначе sing-box не выберет исходящее.
    private static func customConfig(_ payload: String) throws -> [String: Any] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [String: Any]
        else { throw BuildError.badPayload("sing-box JSON") }

        // Панель кладёт в wireguard-endpoint поля amnezia_wg_* — ядро их не знает и
        // отказывается парсить конфиг целиком (`unknown field "disable_cookies"`).
        // Срезаем их, чтобы конфиг хотя бы загрузился и было видно настоящую ошибку.
        var config = sanitize(raw) as? [String: Any] ?? raw

        config["inbounds"] = [inbound()]
        if config["log"] == nil {
            config["log"] = ["level": "info", "timestamp": true]
        }

        var route = (config["route"] as? [String: Any]) ?? [:]
        if route["final"] == nil {
            let outbounds = (config["outbounds"] as? [[String: Any]]) ?? []
            let endpoints = (config["endpoints"] as? [[String: Any]]) ?? []
            if let tag = (outbounds.first?["tag"] as? String) ?? (endpoints.first?["tag"] as? String) {
                route["final"] = tag
            }
        }
        config["route"] = route
        return config
    }
}

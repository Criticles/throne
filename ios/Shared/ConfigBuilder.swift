import Darwin
import Foundation

/// Сборка конфига sing-box для dev-режима: локальный `mixed`-инбаунд + один профиль наружу.
enum ConfigBuilder {
    /// Локальный SOCKS/HTTP, в который смотрит проверка трафика.
    static let listenPort = 7891
    /// Порт, который слушает Turnable-клиент в подписке wireturn (в wgConfig.endpoint).
    static let wireturnPort = 9000
    /// Локальный Clash API: через него замеряем задержку каждого сервера параллельно.
    static let clashPort = 19090

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

    /// Переопределение MTU для WireTurn: поверх TURN/SRTP крупные пакеты теряются,
    /// поэтому WireGuard-MTU приходится опускать ниже панельных 1280.
    static var wireturnMTU: Int?

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
        case .wireguard, .amneziawg:
            // Форк Трона умеет AmneziaWG нативно: endpoint wireguard + вложенный amnezia_wg.
            guard let wg = WireGuardConfig.parse(profile.payload) else {
                throw BuildError.badPayload(profile.payload.lowercased().hasPrefix("amneziawg://")
                    ? "amneziawg:// (base64 wg-quick)" : "wg://")
            }
            config = endpointConfig(endpoint: wireguardEndpoint(
                tag: "wg-out",
                privateKey: wg.privateKey,
                publicKey: wg.publicKey,
                addresses: wg.addresses,
                mtu: wg.mtu,
                keepAlive: wg.keepAlive,
                peerHost: wg.host,
                peerPort: wg.port,
                amnezia: wg.amnezia
            ))
        case .wireturn:
            config = try wireturnConfig(profile.payload, mtu: wireturnMTU)
        case .xray:
            // XHTTP собирает не sing-box, а Xray (см. XrayConfig и DevEngine.startXray).
            throw BuildError.unsupported("VLESS XHTTP обслуживается ядром Xray, а не sing-box")
        case .turnable:
            // Если к транспорту подмешаны ключи WireGuard (см. ProfileStore.pairTurnable) —
            // это полноценный туннель, конфиг тот же, что у WireTurn.
            guard hasWireGuard(profile.payload) else {
                throw BuildError.unsupported("у Turnable нет ключей WireGuard: панель отдаёт их только в формате wireturn")
            }
            config = try wireturnConfig(profile.payload, mtu: wireturnMTU)
        case .custom:
            config = try customConfig(profile.payload)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { throw BuildError.encodingFailed }
        return json
    }

    /// Живой конфиг: все серверы внутри одного ядра, `final` — выбранный.
    ///
    /// Зачем: тогда пинг любого сервера не требует перезапуска ядра и не рвёт текущее
    /// соединение — Clash API спрашивает задержку у конкретного outbound, а трафик идёт
    /// через `final`.
    static func buildLive(profiles: [Profile], selected: Profile?) throws -> (json: String, tags: [UUID: String]) {
        var outbounds: [[String: Any]] = []
        var endpoints: [[String: Any]] = []
        var tags: [UUID: String] = [:]
        var selectedTag: String?

        for profile in profiles {
            let tag = "s\(tags.count)"
            switch profile.kind {
            case .vless:
                guard let link = try? VLESSLink.parse(profile.payload) else { continue }
                var outbound = vlessOutbound(link)
                outbound["tag"] = tag
                outbounds.append(outbound)
            case .hysteria2:
                guard let link = Hysteria2Link.parse(profile.payload) else { continue }
                var outbound = hysteria2Outbound(link)
                outbound["tag"] = tag
                outbounds.append(outbound)
            case .mieru:
                guard let link = MieruLink.parse(profile.payload) else { continue }
                var outbound = mieruOutbound(link)
                outbound["tag"] = tag
                outbounds.append(outbound)
            case .wireguard, .amneziawg:
                guard let wg = WireGuardConfig.parse(profile.payload) else { continue }
                endpoints.append(wireguardEndpoint(
                    tag: tag,
                    privateKey: wg.privateKey,
                    publicKey: wg.publicKey,
                    addresses: wg.addresses,
                    mtu: wg.mtu,
                    keepAlive: wg.keepAlive,
                    peerHost: wg.host,
                    peerPort: wg.port,
                    amnezia: wg.amnezia
                ))
            case .custom:
                // «JSON подписки» — это готовый кусок конфига панели: у WG там endpoint,
                // у остальных outbound. Раньше такие профили выпадали из живого конфига,
                // и `final` уходил в direct — трафик шёл мимо туннеля.
                guard let entry = Self.customEntry(payload: profile.payload, tag: tag) else { continue }
                endpoints.append(contentsOf: entry.endpoints)
                outbounds.append(contentsOf: entry.outbounds)
            default:
                continue
            }
            tags[profile.id] = tag
            if profile.id == selected?.id { selectedTag = tag }
        }

        guard !outbounds.isEmpty || !endpoints.isEmpty else {
            throw BuildError.unsupported("нет серверов, которые sing-box может держать в одном конфиге")
        }
        if let selected, selectedTag == nil {
            // Молча уйти в direct нельзя: трафик пойдёт мимо туннеля. Пусть вызывающий
            // соберёт одиночный конфиг — там ошибка видна.
            throw BuildError.unsupported("профиль «\(selected.name)» не попал в общий конфиг")
        }

        var config: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": dnsConfig(detour: selected?.kind == .wireguard ? selectedTag : nil),
            "inbounds": [inbound()],
            "outbounds": outbounds + [["type": "direct", "tag": "direct"]],
            "route": ["final": selectedTag ?? "direct", "auto_detect_interface": false],
            "experimental": clashAPI(),
        ]
        if !endpoints.isEmpty { config["endpoints"] = endpoints }

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { throw BuildError.encodingFailed }
        return (json, tags)
    }

    /// Один конфиг со всеми серверами сразу — для параллельного пинга через Clash API.
    ///
    /// Clash API (`experimental.clash_api`) умеет отдавать задержку конкретного outbound:
    /// `GET /proxies/<tag>/delay`. Поэтому не нужно поднимать и гасить ядро на каждый сервер —
    /// поднимаем одно с общим списком и меряем все задержки параллельно.
    ///
    /// WireGuard/AmneziaWG сюда не входят: в ядре это `endpoints`, а не outbounds, и Clash API
    /// их не видит. Xray и WireTurn тоже — у них своё ядро и свой транспорт.
    static func pingConfig(profiles: [Profile]) throws -> (json: String, tags: [UUID: String]) {
        var outbounds: [[String: Any]] = []
        var tags: [UUID: String] = [:]

        for profile in profiles {
            let tag = "p\(tags.count)"
            switch profile.kind {
            case .vless:
                guard let link = try? VLESSLink.parse(profile.payload) else { continue }
                var outbound = vlessOutbound(link)
                outbound["tag"] = tag
                outbounds.append(outbound)
                tags[profile.id] = tag
            case .hysteria2:
                guard let link = Hysteria2Link.parse(profile.payload) else { continue }
                var outbound = hysteria2Outbound(link)
                outbound["tag"] = tag
                outbounds.append(outbound)
                tags[profile.id] = tag
            case .mieru:
                guard let link = MieruLink.parse(profile.payload) else { continue }
                var outbound = mieruOutbound(link)
                outbound["tag"] = tag
                outbounds.append(outbound)
                tags[profile.id] = tag
            default:
                continue
            }
        }

        guard !outbounds.isEmpty else {
            throw BuildError.unsupported("нет серверов, которые sing-box может проверить одним конфигом")
        }

        let config: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "dns": dnsConfig(),
            // Инбаунд не нужен для замеров, но с ним ядро ведёт себя как обычно (и пишет порт в лог).
            "inbounds": [inbound()],
            "outbounds": outbounds + [["type": "direct", "tag": "direct"]],
            "route": ["final": "direct", "auto_detect_interface": false],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(clashPort)",
                ],
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { throw BuildError.encodingFailed }
        return (json, tags)
    }

    static func note(for profile: Profile) -> String? {
        profile.note
    }

    // MARK: - Обвязка

    /// DNS ядра: системный резолвер, DoH или DoT — из настроек приложения.
    /// Без блока `dns` sing-box не резолвит имена из SOCKS-запросов, и проверка падает
    /// с «bad URL»/ошибкой прокси.
    private static func dnsConfig(detour: String? = nil) -> [String: Any] {
        // Настройка пользователя: системный резолвер, DoH или DoT.
        let mode = UserDefaults.standard.string(forKey: "prefs.dnsMode") ?? "system"
        let configured = UserDefaults.standard.string(forKey: "prefs.dnsServer") ?? "https://1.1.1.1/dns-query"
        let host = URL(string: configured)?.host ?? configured

        if let detour {
            // Внутри WireGuard системный резолвер недоступен: DNS идёт через сам туннель.
            return [
                "servers": [[
                    "type": "udp",
                    "server": "1.1.1.1",
                    "detour": detour,
                    "tag": "dns-remote",
                ]],
                "final": "dns-remote",
                "strategy": "ipv4_only",
            ]
        }

        switch mode {
        case "doh":
            return [
                "servers": [["type": "https", "server": host, "tag": "dns-remote"]],
                "final": "dns-remote",
            ]
        case "dot":
            return [
                "servers": [["type": "tls", "server": host, "tag": "dns-remote"]],
                "final": "dns-remote",
            ]
        default:
            // Формат 1.12+: у сервера есть тип. Старый вид {"address": "local"} удалён в 1.14.
            return [
                "servers": [["type": "local", "tag": "dns-local"]],
                "final": "dns-local",
            ]
        }
    }

    /// Clash API нужен не только для параллельного пинга: живой трафик и список соединений
    /// тоже берутся из него, поэтому он включён в любом dev-конфиге.
    private static func clashAPI() -> [String: Any] {
        ["clash_api": ["external_controller": "127.0.0.1:\(clashPort)"]]
    }

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
            "dns": dnsConfig(),
            "inbounds": [inbound()],
            "outbounds": [outbound],
            "route": ["final": tag, "auto_detect_interface": false],
            "experimental": clashAPI(),
        ]
    }

    private static func endpointConfig(endpoint: [String: Any]) -> [String: Any] {
        let tag = (endpoint["tag"] as? String) ?? "wg-out"
        return [
            "log": ["level": "info", "timestamp": true],
            "dns": dnsConfig(detour: tag),
            "inbounds": [inbound()],
            "endpoints": [endpoint],
            "route": ["final": tag, "auto_detect_interface": false],
            "experimental": clashAPI(),
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

    /// Есть ли в payload ключи WireGuard (`wg`): у «сырого» Turnable их нет.
    static func hasWireGuard(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return false }
        return root["wg"] is [String: Any]
    }

    /// Уже IP-литерал? Тогда резолв не нужен.
    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Системный резолв имени в IP (getaddrinfo). nil — если имя не разрешилось.
    private static func resolveHost(_ host: String) -> String? {
        if isIPAddress(host) { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            if let address = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: buffer)
                }
            }
            pointer = current.pointee.ai_next
        }
        return nil
    }

    private static func wireguardEndpoint(
        tag: String,
        privateKey: String,
        publicKey: String,
        addresses: [String],
        mtu: Int,
        keepAlive: Int,
        peerHost: String,
        peerPort: Int,
        amnezia: [String: Any]? = nil
    ) -> [String: Any] {
        // Пир может быть задан доменом (WARP: engage.cloudflareclient.com). Через туннель его не
        // разрешить — туннеля ещё нет, DNS-запрос ушёл бы в никуда. Резолвим заранее, системой.
        let resolved = Self.resolveHost(peerHost) ?? peerHost
        var endpoint: [String: Any] = [
            "type": "wireguard",
            "tag": tag,
            "system": false,
            "mtu": mtu,
            "address": addresses,
            "private_key": privateKey,
            "peers": [
                [
                    "address": resolved,
                    "port": peerPort,
                    "public_key": publicKey,
                    "allowed_ips": ["0.0.0.0/0", "::/0"],
                    "persistent_keepalive_interval": keepAlive,
                ]
            ],
        ]
        if let amnezia, !amnezia.isEmpty {
            endpoint["amnezia_wg"] = amnezia
        }
        return endpoint
    }

    /// wireturn: WG-эндпоинт смотрит в локальный порт Turnable (в подписке это `127.0.0.1:9000`).
    private static func wireturnConfig(_ payload: String, mtu override: Int?) throws -> [String: Any] {
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
            mtu: override ?? Int(wg["mtu"] as? String ?? "") ?? 1280,
            keepAlive: Int(wg["persistentKeepalive"] as? String ?? "") ?? 25,
            peerHost: host,
            peerPort: port
        ))
        return config
    }

    /// Достаёт из панельного JSON один endpoint или outbound и перевешивает ему тег.
    private static func customEntry(payload: String, tag: String) -> (outbounds: [[String: Any]], endpoints: [[String: Any]])? {
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any]
        else { return nil }

        if let endpoints = root["endpoints"] as? [[String: Any]],
           var endpoint = endpoints.first,
           let peers = endpoint["peers"] as? [[String: Any]], !peers.isEmpty {
            endpoint = sanitize(endpoint) as? [String: Any] ?? endpoint
            endpoint["tag"] = tag
            if var peerList = endpoint["peers"] as? [[String: Any]] {
                for index in peerList.indices {
                    if let host = peerList[index]["address"] as? String,
                       let resolved = Self.resolveHost(host) {
                        peerList[index]["address"] = resolved
                    }
                }
                endpoint["peers"] = peerList
            }
            return ([], [endpoint])
        }

        if let outbounds = root["outbounds"] as? [[String: Any]] {
            let usable = outbounds.filter {
                ($0["type"] as? String) != "direct"
                    && ($0["type"] as? String) != "block"
                    && ($0["type"] as? String) != "dns"
                    && $0["server"] != nil
            }
            if var outbound = usable.first {
                outbound = sanitize(outbound) as? [String: Any] ?? outbound
                outbound["tag"] = tag
                return ([outbound], [])
            }
        }
        return nil
    }

    /// Убирает ключи, которых нет в ядре: панель дописывает `amnezia_wg_*` в wireguard-endpoint,
    /// а sing-box на неизвестном поле отказывается разбирать конфиг целиком.
    private static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dict {
                if key == "amnezia_wg", let amnezia = item as? [String: Any] {
                    // Ядро знает не все поля AWG 3.x: random_trailers и disable_cookies ему неизвестны,
                    // а на неизвестном поле парсер отказывается читать весь конфиг.
                    var filtered: [String: Any] = [:]
                    for (field, fieldValue) in amnezia
                    where WireGuardConfig.knownAmneziaFields.contains(field) {
                        filtered[field] = fieldValue
                    }
                    result[key] = filtered
                } else {
                    result[key] = sanitize(item)
                }
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
        if config["dns"] == nil {
            // У WireGuard-профилей системный DNS подменён провайдером — резолвим через туннель.
            let endpointTag = ((config["endpoints"] as? [[String: Any]])?.first?["tag"] as? String)
            config["dns"] = dnsConfig(detour: endpointTag)
        }

        var route = (config["route"] as? [String: Any]) ?? [:]
        // Панель ставит true, а платформы (NE) в dev-режиме нет: ядро падает с
        // «no available network interface» на любом outbound. Поэтому не «если nil», а всегда.
        route["auto_detect_interface"] = false

        // Эндпоинты WireGuard приходят с доменом в piere (WARP: engage.cloudflareclient.com).
        // Резолвить его через туннель нельзя — туннеля ещё нет, поэтому подставляем IP заранее.
        if var endpoints = config["endpoints"] as? [[String: Any]] {
            for index in endpoints.indices {
                var endpoint = endpoints[index]
                if var peers = endpoint["peers"] as? [[String: Any]] {
                    for peerIndex in peers.indices {
                        if let host = peers[peerIndex]["address"] as? String,
                           let resolved = Self.resolveHost(host) {
                            peers[peerIndex]["address"] = resolved
                        }
                    }
                    endpoint["peers"] = peers
                }
                endpoints[index] = endpoint
            }
            config["endpoints"] = endpoints
        }
        if route["final"] == nil {
            let outbounds = (config["outbounds"] as? [[String: Any]]) ?? []
            let endpoints = (config["endpoints"] as? [[String: Any]]) ?? []
            if let tag = (outbounds.first?["tag"] as? String) ?? (endpoints.first?["tag"] as? String) {
                route["final"] = tag
            }
        }
        config["route"] = route

        var experimental = (config["experimental"] as? [String: Any]) ?? [:]
        var clash = (experimental["clash_api"] as? [String: Any]) ?? [:]
        if clash["external_controller"] == nil {
            clash["external_controller"] = "127.0.0.1:\(clashPort)"
        }
        experimental["clash_api"] = clash
        config["experimental"] = experimental
        return config
    }
}

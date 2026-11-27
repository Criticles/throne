import Foundation

// Ссылки протоколов, которые чаще всего встречаются в подписках помимо VLESS
// и Hysteria2: Shadowsocks, VMess, Trojan, TUIC. Разбор отдельный от конфига,
// чтобы «Сведения», импорт и сборка outbound'а брали одни и те же значения.

/// Толерантный base64: в ссылках встречается и обычный, и url-safe алфавит,
/// с паддингом и без него.
enum LinkBase64 {
    static func decode(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Хвост из пробелов/переносов панели тоже добавляют.
        text = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " }).joined()
        if !text.hasSuffix("=") {
            let remainder = text.count % 4
            if remainder == 2 { text += "==" }
            if remainder == 3 { text += "=" }
        }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Транспорт и TLS в том виде, в котором их ждёт sing-box.
enum LinkTransport {
    static func make(_ type: String?, path: String?, host: String?,
                     serviceName: String?, mode: String?) -> [String: Any]? {
        guard let raw = type?.lowercased(), !raw.isEmpty, raw != "tcp", raw != "none" else {
            return nil
        }
        switch raw {
        case "ws":
            var transport: [String: Any] = ["type": "ws"]
            if let path, !path.isEmpty { transport["path"] = path }
            if let host, !host.isEmpty { transport["headers"] = ["Host": host] }
            if let mode, mode == "auto" { transport["early_data_header_name"] = "Sec-WebSocket-Protocol" }
            return transport
        case "grpc":
            var transport: [String: Any] = ["type": "grpc"]
            if let serviceName, !serviceName.isEmpty { transport["service_name"] = serviceName }
            return transport
        case "http", "h2":
            var transport: [String: Any] = ["type": "http"]
            if let path, !path.isEmpty { transport["path"] = path }
            if let host, !host.isEmpty { transport["host"] = [host] }
            return transport
        case "httpupgrade":
            var transport: [String: Any] = ["type": "httpupgrade"]
            if let path, !path.isEmpty { transport["path"] = path }
            if let host, !host.isEmpty { transport["host"] = host }
            return transport
        case "quic":
            return ["type": "quic"]
        default:
            // xhttp sing-box не умеет — такой профиль уходит ядру Xray.
            return nil
        }
    }

    static func tls(serverName: String?, alpn: [String], insecure: Bool,
                    fingerprint: String?) -> [String: Any] {
        var tls: [String: Any] = ["enabled": true]
        if let serverName, !serverName.isEmpty { tls["server_name"] = serverName }
        if !alpn.isEmpty { tls["alpn"] = alpn }
        if insecure { tls["insecure"] = true }
        if let fingerprint, !fingerprint.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        return tls
    }
}

// MARK: - Shadowsocks

struct ShadowsocksLink {
    let name: String
    let host: String
    let port: Int
    let method: String
    let password: String
    /// `obfs-local` / `v2ray-plugin` — ядро ждёт их в `plugin`, опции строкой.
    let plugin: String?
    let pluginOpts: String?

    static func parse(_ raw: String) -> ShadowsocksLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ss://") else { return nil }
        var rest = String(trimmed.dropFirst("ss://".count))

        var name = ""
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding ?? ""
            rest = String(rest[..<hash])
        }

        var plugin: String?
        var pluginOpts: String?
        if let mark = rest.firstIndex(of: "?") {
            let query = String(rest[rest.index(after: mark)...])
            rest = String(rest[..<mark])
            for pair in query.split(separator: "&") {
                let item = pair.split(separator: "=", maxSplits: 1)
                guard item.count == 2, item[0].lowercased() == "plugin" else { continue }
                let value = String(item[1]).removingPercentEncoding ?? String(item[1])
                let chunks = value.split(separator: ";").map(String.init)
                plugin = chunks.first
                let options = chunks.dropFirst().joined(separator: ";")
                pluginOpts = options.isEmpty ? nil : options
            }
        }

        // Два варианта: SIP002 (`base64(method:pass)@host:port`) и старый
        // (`base64(method:pass@host:port)` целиком).
        var credentials = ""
        var authority = rest
        if let at = rest.lastIndex(of: "@") {
            credentials = String(rest[..<at])
            authority = String(rest[rest.index(after: at)...])
            if !credentials.contains(":") {
                guard let decoded = LinkBase64.decode(credentials) else { return nil }
                credentials = decoded
            } else {
                credentials = credentials.removingPercentEncoding ?? credentials
            }
        } else {
            guard let decoded = LinkBase64.decode(rest),
                  let at = decoded.lastIndex(of: "@")
            else { return nil }
            credentials = String(decoded[..<at])
            authority = String(decoded[decoded.index(after: at)...])
        }

        guard let colon = credentials.firstIndex(of: ":") else { return nil }
        let method = String(credentials[..<colon]).lowercased()
        let password = String(credentials[credentials.index(after: colon)...])
        guard !method.isEmpty, !password.isEmpty else { return nil }

        guard let portColon = authority.lastIndex(of: ":"),
              let port = Int(authority[authority.index(after: portColon)...])
        else { return nil }
        let host = String(authority[..<portColon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }

        return ShadowsocksLink(name: name.isEmpty ? "\(host):\(port)" : name,
                               host: host, port: port, method: method, password: password,
                               plugin: plugin, pluginOpts: pluginOpts)
    }
}

// MARK: - VMess

struct VMessLink {
    let name: String
    let host: String
    let port: Int
    let uuid: String
    let security: String
    let alterID: Int
    let network: String?
    let path: String?
    let hostHeader: String?
    let serviceName: String?
    let tlsEnabled: Bool
    let serverName: String?
    let alpn: [String]
    let fingerprint: String?

    static func parse(_ raw: String) -> VMessLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vmess://") else { return nil }
        let body = String(trimmed.dropFirst("vmess://".count))
        guard let decoded = LinkBase64.decode(body),
              let data = decoded.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        func text(_ key: String) -> String? {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? Int { return String(value) }
            return nil
        }

        guard let host = text("add"),
              let portText = text("port"), let port = Int(portText),
              let uuid = text("id")
        else { return nil }

        let tlsValue = (text("tls") ?? "").lowercased()
        let alpn = (text("alpn") ?? "").split(separator: ",").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VMessLink(
            name: text("ps") ?? "\(host):\(port)",
            host: host,
            port: port,
            uuid: uuid,
            security: text("scy") ?? "auto",
            alterID: Int(text("aid") ?? "") ?? 0,
            network: text("net"),
            path: text("path"),
            hostHeader: text("host"),
            serviceName: text("path"),
            tlsEnabled: tlsValue == "tls" || tlsValue == "reality",
            serverName: text("sni") ?? text("host"),
            alpn: alpn,
            fingerprint: text("fp")
        )
    }
}

// MARK: - Trojan

struct TrojanLink {
    let name: String
    let host: String
    let port: Int
    let password: String
    let serverName: String?
    let alpn: [String]
    let insecure: Bool
    let fingerprint: String?
    let transport: String?
    let path: String?
    let hostHeader: String?
    let serviceName: String?

    static func parse(_ raw: String) -> TrojanLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("trojan://"),
              let parts = LinkParts.parse(trimmed),
              let port = parts.firstPort
        else { return nil }

        let password = parts.password.isEmpty ? parts.user : "\(parts.user):\(parts.password)"
        guard !password.isEmpty else { return nil }

        let alpn = (parts.query["alpn"] ?? "").split(separator: ",").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let insecure = (parts.query["allowinsecure"] ?? "") == "1"
            || (parts.query["insecure"] ?? "") == "1"
            || (parts.query["allow_insecure"] ?? "") == "1"

        return TrojanLink(
            name: parts.fragment ?? "\(parts.host):\(port)",
            host: parts.host,
            port: port,
            password: password,
            serverName: parts.query["sni"] ?? parts.query["peer"],
            alpn: alpn,
            insecure: insecure,
            fingerprint: parts.query["fp"],
            transport: parts.query["type"],
            path: parts.query["path"],
            hostHeader: parts.query["host"],
            serviceName: parts.query["serviceName"] ?? parts.query["servicename"]
        )
    }
}

// MARK: - TUIC

struct TUICLink {
    let name: String
    let host: String
    let port: Int
    let uuid: String
    let password: String
    let congestionControl: String
    let udpRelayMode: String
    let serverName: String?
    let alpn: [String]
    let insecure: Bool

    static func parse(_ raw: String) -> TUICLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("tuic://"),
              let parts = LinkParts.parse(trimmed),
              let port = parts.firstPort
        else { return nil }
        guard !parts.user.isEmpty, !parts.password.isEmpty else { return nil }

        let alpn = (parts.query["alpn"] ?? "").split(separator: ",").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let insecure = (parts.query["allow_insecure"] ?? "") == "1"
            || (parts.query["allowinsecure"] ?? "") == "1"
            || (parts.query["insecure"] ?? "") == "1"

        return TUICLink(
            name: parts.fragment ?? "\(parts.host):\(port)",
            host: parts.host,
            port: port,
            uuid: parts.user,
            password: parts.password,
            congestionControl: parts.query["congestion_control"] ?? "bbr",
            udpRelayMode: parts.query["udp_relay_mode"] ?? "native",
            serverName: parts.query["sni"],
            alpn: alpn.isEmpty ? ["h3"] : alpn,
            insecure: insecure
        )
    }
}

// MARK: - MasterDNS

/// DNS-туннель MasterDNS. В Throne PC он принимает четыре формата; здесь — два,
/// которые встречаются в подписках: `masterdns://v1?…` (query) и
/// `masterdns://<base64 JSON>` (schema `masterdns.profile` / `whitedns.profile`).
struct MasterDNSLink {
    let name: String
    let domains: [String]
    let encryptionKey: String
    let encryptionMethod: String
    let mode: String
    let resolvers: [String]
    let balancing: String?
    let duplication: Int?

    /// Индексы совпадают с `masterDnsEncryptionMethods` в форке.
    static let methods = ["none", "xor", "chacha20", "aes-128-gcm", "aes-192-gcm", "aes-256-gcm"]
    /// `balancing_strategy`: ноль означает «как в ядре по умолчанию».
    static let balancingNames = ["round_robin", "random", "round_robin", "least_loss",
                                 "lowest_latency", "hybrid", "loss_then_latency",
                                 "least_loss_top_random", "least_loss_top_round_robin"]

    static func parse(_ raw: String) -> MasterDNSLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("masterdns://") else { return nil }
        var body = String(trimmed.dropFirst("masterdns://".count))

        var name = ""
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding ?? ""
            body = String(body[..<hash])
        }

        // `v1?…` — формат yptun: домены, ключ, метод шифрования, резолверы в query.
        if body.lowercased().hasPrefix("v1") {
            var query = body
            if query.lowercased().hasPrefix("v1") {
                query = String(query.dropFirst(2))
            }
            if query.hasPrefix("?") { query.removeFirst() }
            var values: [String: String] = [:]
            for pair in query.split(separator: "&") {
                let item = pair.split(separator: "=", maxSplits: 1)
                let key = String(item[0]).removingPercentEncoding?.lowercased()
                    ?? String(item[0]).lowercased()
                guard !key.isEmpty, values[key] == nil else { continue }
                let value = item.count == 2
                    ? (String(item[1]).removingPercentEncoding ?? String(item[1]))
                    : ""
                values[key] = value
            }
            let domains = splitList(values["domains"] ?? "")
            guard !domains.isEmpty else { return nil }
            return MasterDNSLink(
                name: name.isEmpty ? domains[0] : name,
                domains: domains,
                encryptionKey: values["key"] ?? "",
                encryptionMethod: method(from: values["enc"]),
                mode: "socks5",
                resolvers: splitList(values["resolvers"] ?? ""),
                balancing: balancing(from: values["bal"]),
                duplication: count(from: values["dup"])
            )
        }

        // `v1/<base64 TOML>` — клиентский конфиг в TOML; его разбор оставлен PC-версии.
        if body.lowercased().hasPrefix("v1/") { return nil }

        // Иначе — base64 от JSON-профиля.
        guard let decoded = LinkBase64.decode(body),
              let data = decoded.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let schema = (root["schema"] as? String ?? "").lowercased()
        let known = ["whitedns.profile", "masterdns.profile", "stormdns.profile"]
        guard known.contains(schema) else { return nil }
        guard (root["version"].map { String(describing: $0) } ?? "") == "1" else { return nil }

        let profile = root["profile"] as? [String: Any] ?? [:]
        let server = profile["server"] as? [String: Any] ?? [:]
        func pick(_ snake: String, _ camel: String) -> Any? {
            server[snake] ?? server[camel]
        }

        var domains: [String] = []
        if let domain = server["domain"] as? String, !domain.isEmpty { domains.append(domain) }
        domains += splitList(((server["domains"] as? [String]) ?? []).joined(separator: ","))
        guard !domains.isEmpty else { return nil }

        let methodValue = pick("encryption_method", "encryptionMethod")
        let methodText: String
        if let number = methodValue as? Int {
            methodText = String(number)
        } else if let number = methodValue as? Double {
            methodText = String(Int(number))
        } else {
            methodText = methodValue as? String ?? ""
        }

        return MasterDNSLink(
            name: (profile["name"] as? String) ?? (name.isEmpty ? domains[0] : name),
            domains: domains,
            encryptionKey: (pick("encryption_key", "encryptionKey") as? String) ?? "",
            encryptionMethod: method(from: methodText),
            mode: "socks5",
            resolvers: [],
            balancing: nil,
            duplication: nil
        )
    }

    /// Списки в ссылке разделяются запятой, точкой с запятой или пробелом.
    private static func splitList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func method(from text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "xor" }
        if let index = Int(value), index >= 0, index < methods.count { return methods[index] }
        return methods.contains(value) ? value : "xor"
    }

    private static func balancing(from text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              let index = Int(value), index >= 0, index < balancingNames.count, index != 0
        else { return nil }
        return balancingNames[index]
    }

    private static func count(from text: String?) -> Int? {
        guard let value = text?.trimmingCharacters(in: .whitespaces),
              let number = Int(value), number > 0
        else { return nil }
        return number
    }
}

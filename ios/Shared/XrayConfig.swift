import Foundation

/// Сборка конфига Xray для профилей, которые sing-box не умеет.
///
/// Пока это VLESS + XHTTP: панель отдаёт такую ссылку с `type=xhttp`, а sing-box поддерживает
/// только tcp/ws/grpc/quic. Xray поднимается рядом с sing-box (оба линкуются в Libbox) и
/// слушает собственный socks-инбаунд на 127.0.0.1:7892 — через него идёт проверка.
enum XrayConfig {
    /// Локальный socks-порт Xray. Не пересекается с mixed-инбаундом sing-box (7891).
    static let socksPort = 7892
    /// Первый порт общего конфига: по одному входу на сервер, как у sing-box в 21000+.
    static let socksPortBase = 7892

    /// Общий конфиг: по socks-входу и outbound'у на каждый XHTTP-сервер, правила разводят
    /// вход в свой сервер. Так Xray меряет все свои профили разом, а не перезапуском на каждый.
    static func buildPool(links: [(id: UUID, link: VLESSLink)]) -> (json: String, ports: [UUID: Int]) {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        var ports: [UUID: Int] = [:]
        for (index, entry) in links.enumerated() {
            let port = socksPortBase + index
            let inTag = "socks-" + String(index)
            let outTag = "proxy-" + String(index)
            inbounds.append([
                "tag": inTag,
                "listen": "127.0.0.1",
                "port": port,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": true],
            ])
            outbounds.append(outbound(link: entry.link, tag: outTag))
            rules.append(["type": "field", "inboundTag": [inTag], "outboundTag": outTag])
            ports[entry.id] = port
        }
        outbounds.append(["protocol": "freedom", "tag": "direct"])
        let config: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["rules": rules],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return ("{}", [:]) }
        return (json, ports)
    }

    static func build(link: VLESSLink) -> [String: Any] {
        return [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": socksPort,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": true],
            ]],
            "outbounds": [outbound(link: link, tag: "proxy")],
        ]
    }

    private static func outbound(link: VLESSLink, tag: String) -> [String: Any] {
        var user: [String: Any] = ["id": link.uuid, "encryption": "none"]
        if let flow = link.flow, !flow.isEmpty {
            user["flow"] = flow
        }

        var stream: [String: Any] = [
            "network": link.transport.isEmpty ? "tcp" : link.transport,
        ]

        switch link.security.lowercased() {
        case "reality":
            stream["security"] = "reality"
            var reality: [String: Any] = ["serverName": link.serverName ?? link.host]
            if let fingerprint = link.fingerprint { reality["fingerprint"] = fingerprint }
            if let publicKey = link.publicKey { reality["publicKey"] = publicKey }
            if let shortID = link.shortID { reality["shortId"] = shortID }
            stream["realitySettings"] = reality
        case "tls":
            stream["security"] = "tls"
            var tls: [String: Any] = ["serverName": link.serverName ?? link.host]
            if let fingerprint = link.fingerprint { tls["fingerprint"] = fingerprint }
            if !link.alpn.isEmpty { tls["alpn"] = link.alpn }
            stream["tlsSettings"] = tls
        default:
            stream["security"] = "none"
        }

        // XHTTP: путь, Host-заголовок, режим и extra-объект (uplinkHTTPMethod и прочее).
        if link.transport == "xhttp" {
            var xhttp: [String: Any] = [:]
            if let path = link.path { xhttp["path"] = path }
            if let host = link.hostHeader { xhttp["host"] = host }
            if let mode = link.mode { xhttp["mode"] = mode }
            if let extra = link.extra,
               let data = extra.removingPercentEncoding?.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any] {
                xhttp["extra"] = dict
            }
            stream["xhttpSettings"] = xhttp
        }

        return [
            "tag": tag,
            "protocol": "vless",
            "settings": [
                "vnext": [[
                    "address": link.host,
                    "port": link.port,
                    "users": [user],
                ]],
            ],
            "streamSettings": stream,
        ]
    }
}

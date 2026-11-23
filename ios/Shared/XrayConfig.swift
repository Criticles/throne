import Foundation

/// Сборка конфига Xray для профилей, которые sing-box не умеет.
///
/// Пока это VLESS + XHTTP: панель отдаёт такую ссылку с `type=xhttp`, а sing-box поддерживает
/// только tcp/ws/grpc/quic. Xray поднимается рядом с sing-box (оба линкуются в Libbox) и
/// слушает собственный socks-инбаунд на 127.0.0.1:7892 — через него идёт проверка.
enum XrayConfig {
    /// Локальный socks-порт Xray. Не пересекается с mixed-инбаундом sing-box (7891).
    static let socksPort = 7892

    static func build(link: VLESSLink) -> [String: Any] {
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

        let outbound: [String: Any] = [
            "tag": "proxy",
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

        return [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": socksPort,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": true],
            ]],
            "outbounds": [outbound],
        ]
    }
}

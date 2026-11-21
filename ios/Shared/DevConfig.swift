import Foundation

/// Конфиг для dev-режима: sing-box поднимает локальный SOCKS/mixed-инбаунд,
/// наружу выходит через один VLESS-профиль.
///
/// Это не «системный VPN» и не требует Network Extension — поэтому работает
/// и в обычной подписи, и внутри LiveContainer.
enum DevConfig {
    static let listenPort = 7891

    enum BuildError: LocalizedError {
        case encodingFailed
        case unsupportedSecurity(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "не удалось собрать конфиг"
            case .unsupportedSecurity(let value): return "security=\(value) пока не поддержан в dev-режиме"
            }
        }
    }

    static func build(link: VLESSLink) throws -> String {
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
            var tls: [String: Any] = [
                "enabled": true,
                "server_name": link.serverName ?? link.host,
            ]
            var reality: [String: Any] = ["enabled": true]
            if let key = link.publicKey { reality["public_key"] = key }
            if let sid = link.shortID { reality["short_id"] = sid }
            tls["reality"] = reality
            if let fingerprint = link.fingerprint {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            outbound["tls"] = tls
        case "tls":
            var tls: [String: Any] = [
                "enabled": true,
                "server_name": link.serverName ?? link.host,
            ]
            if let fingerprint = link.fingerprint {
                tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
            }
            outbound["tls"] = tls
        case "none":
            break
        default:
            throw BuildError.unsupportedSecurity(link.security)
        }

        let config: [String: Any] = [
            "log": ["level": "debug", "timestamp": true],
            "inbounds": [
                [
                    "type": "mixed",
                    "tag": "mixed-in",
                    "listen": "127.0.0.1",
                    "listen_port": listenPort,
                ]
            ],
            "outbounds": [outbound],
            "route": ["final": "proxy"],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            throw BuildError.encodingFailed
        }
        return json
    }
}

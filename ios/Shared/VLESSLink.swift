import Foundation

/// Разбор share-ссылки `vless://`.
///
/// Пока поддерживается то, что нужно для dev-режима: VLESS + TCP + TLS/REALITY.
/// Остальные транспорты (ws/grpc/xhttp), а также vmess/trojan/ss/hy2 — в P1.
struct VLESSLink {
    let name: String
    let uuid: String
    let host: String
    let port: Int
    let flow: String?
    let security: String
    let serverName: String?
    let fingerprint: String?
    let publicKey: String?
    let shortID: String?
    let packetEncoding: String?

    enum ParseError: LocalizedError {
        case notVLESS
        case badURL
        case missingHostOrUUID

        var errorDescription: String? {
            switch self {
            case .notVLESS: return "это не vless:// ссылка"
            case .badURL: return "не разобрать ссылку"
            case .missingHostOrUUID: return "в ссылке нет адреса сервера или UUID"
            }
        }
    }

    static func parse(_ raw: String) throws -> VLESSLink {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vless://") else { throw ParseError.notVLESS }
        guard let components = URLComponents(string: trimmed) else { throw ParseError.badURL }
        guard let host = components.host, !host.isEmpty,
              let uuid = components.user, !uuid.isEmpty,
              let port = components.port
        else { throw ParseError.missingHostOrUUID }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                query[item.name.lowercased()] = value
            }
        }

        let name = components.fragment?.removingPercentEncoding ?? "\(host):\(port)"

        return VLESSLink(
            name: name,
            uuid: uuid,
            host: host,
            port: port,
            flow: query["flow"].flatMap { $0.isEmpty ? nil : $0 },
            security: query["security"] ?? "none",
            serverName: query["sni"],
            fingerprint: query["fp"],
            publicKey: query["pbk"],
            shortID: query["sid"],
            packetEncoding: query["packetencoding"]
        )
    }
}

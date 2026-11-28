import Foundation
import CryptoKit

/// WARP через AmneziaWG: Cloudflare принимает обычный WireGuard-хендшейк, а junk-пакеты
/// и `I1` перед ним проходят DPI там, где чистый WireGuard режется.
/// Параметры подобраны сканером warpscout на этой сети: 42 из 42 эндпоинтов поднялись.
enum WARPCreator {
    /// Публичный ключ WARP (одинаковый у всех клиентов Cloudflare).
    static let peerKey = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    /// Маска первого пакета под QUIC: DPI видит не WireGuard, а что-то похожее на QUIC.
    static let i1 = "<b 0xc60000000101f60000405a1d30a806854f33b009c25e2d33f616910cbbaae8>"
        + "<r 23>"
        + "<b 0xdd5b5ce8632ae4fc9691c9f06bbd2d7282f5a988052c1d0aa74e6a8e3e873f><r 16>"

    /// Проверенные эндпоинты: узел HEL (Хельсинки), снаружи видно как FI.
    static let endpoints = [
        "8.34.146.236:2408",
        "8.47.69.12:2408",
        "162.159.192.55:2408",
        "188.114.96.222:500",
        "8.6.112.77:500",
        "162.159.195.250:2408",
        "8.35.211.205:2408",
        "188.114.99.209:2408",
    ]

    struct Account {
        let privateKey: String
        let address: String
        let peerPublicKey: String
    }

    /// Регистрация WARP-аккаунта: отдаём свой публичный ключ, получаем адрес и ключ пира.
    static func register() async throws -> Account {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        // Старый адрес api.cloudflareclient.com заблокирован: соединение рвётся на TLS.
        // Рабочий адрес — из клиента текущей версии WARP.
        var request = URLRequest(url: URL(string: "https://api.devices.cloudflare.com/v0a4471/reg")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("a-6.11-2223", forHTTPHeaderField: "CF-Client-Version")
        request.setValue("okhttp/3.12.1", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "key": publicKey,
            "install_id": "",
            "fcm_token": "",
            "tos": ISO8601DateFormatter().string(from: Date()),
            "model": "PC",
            "type": "Windows",
            "locale": "en_US",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WARPError.registration }
        // Новый адрес отдаёт объект сразу, старый — завёрнутым в `result`.
        let root = (json["result"] as? [String: Any]) ?? json
        guard let config = root["config"] as? [String: Any],
              let peers = config["peers"] as? [[String: Any]],
              let first = peers.first,
              let peerPublic = first["public_key"] as? String
        else { throw WARPError.registration }

        var address = "172.16.0.2/32"
        if let interface = config["interface"] as? [String: Any],
           let addresses = interface["addresses"] as? [String: Any],
           let v4 = addresses["v4"] as? String, !v4.isEmpty {
            address = v4.contains("/") ? v4 : v4 + "/32"
        }
        return Account(privateKey: privateKey.rawRepresentation.base64EncodedString(),
                       address: address,
                       peerPublicKey: peerPublic)
    }

    /// Ключи уже созданного профиля — чтобы сменить эндпоинт, не регистрируясь заново.
    static func account(from payload: String) -> Account? {
        guard let wg = WireGuardConfig.parse(payload) else { return nil }
        return Account(privateKey: wg.privateKey,
                       address: wg.addresses.first ?? "172.16.0.2/32",
                       peerPublicKey: wg.publicKey)
    }

    /// Ссылка `wg://`, которую разбирает WireGuardConfig: те же поля, что в wg-quick,
    /// плюс junk-параметры AmneziaWG.
    static func payload(account: Account, endpoint: String) -> String {
        let parts = endpoint.split(separator: ":")
        let host = parts.first.map(String.init) ?? endpoint
        let port = parts.count > 1 ? String(parts[1]) : "2408"

        var components = URLComponents()
        components.scheme = "wg"
        components.host = host
        components.port = Int(port)
        components.queryItems = [
            URLQueryItem(name: "private_key", value: account.privateKey),
            URLQueryItem(name: "public_key", value: account.peerPublicKey),
            URLQueryItem(name: "local_address", value: account.address),
            URLQueryItem(name: "mtu", value: "1280"),
            URLQueryItem(name: "persistent_keepalive_interval", value: "25"),
            URLQueryItem(name: "jc", value: "6"),
            URLQueryItem(name: "jmin", value: "10"),
            URLQueryItem(name: "jmax", value: "50"),
            URLQueryItem(name: "i1", value: i1),
        ]
        components.fragment = "WARP · " + host
        return components.string ?? "wg://\(host):\(port)"
    }

    enum WARPError: LocalizedError {
        case registration
        var errorDescription: String? {
            switch self {
            case .registration:
                return "Cloudflare не выдал аккаунт — проверь интернет и попробуй ещё раз"
            }
        }
    }
}

import Foundation

/// Локальный Clash API ядра: единственный способ узнать задержку конкретного outbound,
/// не перезапуская ядро. Слушает 127.0.0.1:19090 (см. `ConfigBuilder.clashPort`).
enum ClashApi {
    static var port: Int { ConfigBuilder.clashPort }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        // Локальный порт — напрямую, без системного прокси.
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Отвечает ли Clash API: ядро поднимает его вместе с сервисом, но не мгновенно.
    static func version() async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/version") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    /// Задержка outbound по тегу: ядро само делает запрос по указанному url через этот сервер.
    /// `timeout` — в миллисекундах (так его ждёт API).
    static func delay(tag: String, url target: String, timeout: Int = 4000) async -> Int? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/proxies/\(tag)/delay"
        components.queryItems = [
            URLQueryItem(name: "url", value: target),
            URLQueryItem(name: "timeout", value: String(timeout)),
        ]
        guard let url = components.url else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else { return nil }
        if let delay = object["delay"] as? Int, delay > 0 { return delay }
        if let delay = object["delay"] as? Double, delay > 0 { return Int(delay) }
        return nil
    }

    /// Активные соединения: хост, куда шли, через какой сервер и по какому правилу.
    /// Clash API отдаёт это в `/connections`, поэтому статистика не требует своего учёта.
    struct Connection: Identifiable {
        let id = UUID()
        let host: String
        let chain: [String]
        let rule: String
        let upload: Int
        let download: Int
    }

    static func connections() async -> [Connection] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/connections") else { return [] }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any],
              let list = object["connections"] as? [[String: Any]]
        else { return [] }

        return list.map { item in
            let metadata = item["metadata"] as? [String: Any]
            let host = (metadata?["host"] as? String)
                ?? (metadata?["destinationIP"] as? String)
                ?? "?"
            let chain = item["chains"] as? [String] ?? []
            let rule = (item["rule"] as? String) ?? "final"
            return Connection(host: host,
                              chain: chain,
                              rule: rule,
                              upload: item["upload"] as? Int ?? 0,
                              download: item["download"] as? Int ?? 0)
        }
    }
}

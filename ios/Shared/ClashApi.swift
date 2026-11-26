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
    static func delay(tag: String, url target: String, timeout: Int = 3000) async -> Int? {
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

    /// Активное соединение: как в списке настольного клиента — адрес, откуда, протокол,
    /// по какому правилу и через какой сервер, объём и время начала.
    struct Connection: Identifiable {
        let id: String
        let host: String
        let ip: String
        let port: Int
        let source: String
        let network: String
        let proto: String
        let process: String
        let rule: String
        let rulePayload: String
        let chain: [String]
        let upload: Int
        let download: Int
        let start: Date?

        /// «193.203.43.45:19302» или «api.vk.ru:443».
        var destination: String {
            let name = host.isEmpty ? ip : host
            guard !name.isEmpty else { return "—" }
            return port > 0 ? name + ":" + String(port) : name
        }

        var outbound: String { chain.last ?? "—" }

        /// Служебное соединение — наш собственный замер пинга: ядро описывает правило
        /// как `inbound=probe-s25 => route(s25)`. У таких нет значения правила,
        /// и в маршруте они ни одной папке не соответствуют.
        var isService: Bool {
            rule.lowercased().contains("probe-")
                || proto.lowercased().contains("probe-")
        }

        var processText: String {
            process.isEmpty ? "" : process
        }
    }

    /// Итоги ядра с момента его запуска: Clash API отдаёт их рядом со списком.
    struct Totals {
        var download: Int64 = 0
        var upload: Int64 = 0
    }

    static func connections() async -> [Connection] {
        await snapshot().list
    }

    /// Список соединений и накопленный трафик за один запрос.
    static func snapshot() async -> (list: [Connection], totals: Totals) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/connections") else {
            return ([], Totals())
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any],
              let list = object["connections"] as? [[String: Any]]
        else { return ([], Totals()) }

        let totals = Totals(download: int64Value(object["downloadTotal"]),
                            upload: int64Value(object["uploadTotal"]))

        let items = list.map { item in
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            let host = (metadata["host"] as? String) ?? ""
            let ip = (metadata["destinationIP"] as? String) ?? ""
            let port = intValue(metadata["destinationPort"]) ?? 0
            let sourceIP = (metadata["sourceIP"] as? String) ?? ""
            let sourcePort = intValue(metadata["sourcePort"]) ?? 0
            let process = (metadata["process"] as? String)
                ?? (metadata["processPath"] as? String)
                ?? ""
            let proto = (metadata["protocol"] as? String)
                ?? (metadata["type"] as? String)
                ?? ""
            return Connection(
                id: (item["id"] as? String) ?? UUID().uuidString,
                host: host,
                ip: ip,
                port: port,
                source: sourcePort > 0 ? "\(sourceIP):\(sourcePort)" : sourceIP,
                network: (metadata["network"] as? String) ?? "",
                proto: proto,
                process: process,
                rule: (item["rule"] as? String) ?? "final",
                rulePayload: (item["rulePayload"] as? String) ?? "",
                chain: item["chains"] as? [String] ?? [],
                upload: intValue(item["upload"]) ?? 0,
                download: intValue(item["download"]) ?? 0,
                start: parseDate(item["start"])
            )
        }
        return (items, totals)
    }

    /// Число любого вида: Int, Double или строка.
    private static func int64Value(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }

    /// В JSON числа приходят то числами, то строками — приводим оба варианта.
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let double = value as? Double { return Int(double) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

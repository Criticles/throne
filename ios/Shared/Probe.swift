import Foundation

/// Результат проверки туннеля: не просто «HTTP 200», а с какого адреса и из какой страны
/// нас видит интернет — это и есть ответ на «работает ли сервер».
struct ProbeResult {
    var ok = false
    var ip: String?
    var country: String?
    var countryCode: String?
    var city: String?
    var isp: String?
    var millis: Int?
    var error: String?

    /// «IP 1.2.3.4 · 🇩🇪 Германия · Berlin · 412 мс» либо «ошибка: …».
    var summary: String {
        guard ok, let ip else { return "нет связи — \(error ?? "неизвестная ошибка")" }
        var parts = ["IP \(ip)"]
        if let country, !country.isEmpty {
            let flag = Probe.flag(countryCode)
            parts.append(flag.isEmpty ? country : "\(flag) \(country)")
        }
        if let city, !city.isEmpty {
            parts.append(city)
        }
        if let millis {
            parts.append("\(millis) мс")
        }
        return parts.joined(separator: " · ")
    }
}

/// Проверка выхода в интернет через локальный mixed-инбаунд ядра.
enum Probe {
    /// ip-api.com отвечает по HTTP и умеет русские названия стран;
    /// ipinfo.io — резерв, если первый недоступен.
    static func viaProxy(port: Int) async -> ProbeResult {
        let started = Date()
        var result = await ask("http://ip-api.com/json/?fields=status,country,countryCode,city,isp,query&lang=ru",
                               port: port, started: started)
        if !result.ok {
            // Резерв, если ip-api недоступен: у него другой формат ответа.
            let reserve = await ask("https://ipinfo.io/json", port: port, started: started)
            if reserve.ok { result = reserve }
        }
        // Время ip-api — это задержка до чужого веб-сервиса с его обработкой, а не ping до выхода.
        // Поэтому задержку меряем отдельно: пустой ответ Cloudflare, один круг до сервера.
        result.millis = await latency(port: port)
        return result
    }

    /// Задержка «до выхода»: `generate_204` отдаёт пустой ответ по HTTP,
    /// то есть это фактически один RTT через туннель, без TLS и без работы сервиса.
    private static func latency(port: Int) async -> Int? {
        guard let url = URL(string: "http://cp.cloudflare.com/generate_204") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let session = URLSession(configuration: configuration)
        let clock = Date()
        do {
            _ = try await session.data(from: url)
            return Int(Date().timeIntervalSince(clock) * 1000)
        } catch {
            return nil
        }
    }

    private static func ask(_ raw: String, port: Int, started: Date) async -> ProbeResult {
        guard let url = URL(string: raw) else {
            return ProbeResult(ok: false, error: "некорректный URL проверки")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        // mixed-инбаунд понимает и HTTP CONNECT, и SOCKS5; через HTTP-прокси CFNetwork надёжнее.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let session = URLSession(configuration: configuration)
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any]
            else {
                return ProbeResult(ok: false, error: "HTTP \(status)")
            }
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            if let ip = json["query"] as? String {
                return ProbeResult(ok: true, ip: ip,
                                   country: json["country"] as? String,
                                   countryCode: json["countryCode"] as? String,
                                   city: json["city"] as? String,
                                   isp: json["isp"] as? String,
                                   millis: millis)
            }
            if let ip = json["ip"] as? String {
                let code = json["country"] as? String
                return ProbeResult(ok: true, ip: ip,
                                   country: code,
                                   countryCode: code,
                                   city: json["city"] as? String,
                                   isp: json["org"] as? String,
                                   millis: millis)
            }
            return ProbeResult(ok: false, error: "ответ без адреса")
        } catch {
            let ns = error as NSError
            return ProbeResult(ok: false,
                               error: "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]")
        }
    }

    /// Код страны → флаг-эмодзи («DE» → 🇩🇪).
    static func flag(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "" }
        let base: UInt32 = 0x1F1E6
        var scalars = String.UnicodeScalarView()
        for character in code.uppercased().unicodeScalars {
            guard let scalar = UnicodeScalar(base + character.value - 65) else { return "" }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

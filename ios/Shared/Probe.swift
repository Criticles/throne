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

    /// «IP 1.2.3.4 · 🇩🇪 Германия · Berlin · 412 мс» либо «нет связи: …».
    var summary: String {
        guard ok, let ip else { return "нет связи — \(error ?? "неизвестная ошибка")" }
        var parts = ["IP \(ip)"]
        if let name = Probe.countryName(code: countryCode, fallback: country) {
            parts.append(name)
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
    /// Основной источник — Cloudflare trace: отдаёт `ip=` и `loc=`, живёт на CDN,
    /// не отвечает 502 и не требует ключей. ipinfo/ip-api — только резерв.
    static func viaProxy(port: Int) async -> ProbeResult {
        if let result = await trace(port: port) { return result }

        var result = await ask("https://ipinfo.io/json", port: port, started: Date())
        if !result.ok {
            let reserve = await ask("http://ip-api.com/json/?fields=status,country,countryCode,city,isp,query&lang=ru",
                                    port: port, started: Date())
            if reserve.ok { result = reserve }
        }
        // Время этих сервисов — их собственная обработка; задержку меряем отдельно.
        result.millis = result.millis ?? (await latency(port: port))
        return result
    }

    // MARK: - Cloudflare trace

    private static func trace(port: Int) async -> ProbeResult? {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.connectionProxyDictionary = proxySettings(port: port)
        let session = URLSession(configuration: configuration)
        let clock = Date()
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let ip = fields["ip"], !ip.isEmpty else { return nil }
            let code = fields["loc"]
            return ProbeResult(ok: true, ip: ip,
                               country: countryName(code: code, fallback: nil),
                               countryCode: code,
                               millis: Int(Date().timeIntervalSince(clock) * 1000))
        } catch {
            return nil
        }
    }

    private static func proxySettings(port: Int) -> [AnyHashable: Any] {
        // mixed-инбаунд понимает и HTTP CONNECT, и SOCKS5; через HTTP-прокси CFNetwork надёжнее.
        [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
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

    /// Код страны → «🇩🇪 Германия»: имя локализованное, по-русски.
    static func countryName(code: String?, fallback: String?) -> String? {
        guard let code, code.count == 2 else { return fallback }
        let name = Locale(identifier: "ru_RU").localizedString(forRegionCode: code.uppercased()) ?? code
        let flag = self.flag(code)
        return flag.isEmpty ? name : "\(flag) \(name)"
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

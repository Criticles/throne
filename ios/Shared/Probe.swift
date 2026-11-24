import Darwin
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

    /// Одна фраза на любой провал: подробности — в «Сведениях» и журнале,
    /// в списке пользователю достаточно «Недоступен».
    static let unavailable = "Недоступен"

    /// Третья строка строки списка: флаг, страна по-русски и выходной IP.
    /// nil — значит провал, тогда показываем `ProbeResult.unavailable`.
    var exitLine: String? {
        guard ok else { return nil }
        var parts: [String] = []
        if let name = Probe.countryName(code: countryCode, fallback: country) {
            parts.append(name)
        }
        if let ip, !ip.isEmpty {
            parts.append(ip)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// «🇫🇮 FI · 186 мс» — для строки списка: страна кодом, чтобы всё влезало в одну строку.
    var shortSummary: String {
        guard ok else { return error ?? "нет связи" }
        var parts: [String] = []
        if let short = Probe.shortCountry(code: countryCode) { parts.append(short) }
        if let millis { parts.append("\(millis) мс") }
        if parts.isEmpty, let ip { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

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
        if var result = await trace(port: port) {
            // Замер задержки — отдельно: у trace время включает TLS и работу CDN.
            result.millis = await ping(port: port) ?? result.millis
            return result
        }

        var result = await ask("https://ipinfo.io/json", port: port, started: Date())
        if !result.ok {
            let reserve = await ask("http://ip-api.com/json/?fields=status,country,countryCode,city,isp,query&lang=ru",
                                    port: port, started: Date())
            if reserve.ok { result = reserve }
        }
        // Время этих сервисов — их собственная обработка; задержку меряем отдельно.
        result.millis = await ping(port: port) ?? result.millis
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

    /// Проба с потолком по времени: если профиль мёртв (хендшейк не отвечает),
    /// резервные сервисы внутри тянутся десятками секунд — очередь этого ждать не должна.
    static func timed(port: Int, timeout: Double) async -> ProbeResult? {
        await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await viaProxy(port: port) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Пинг как в клиентах: один круг до выхода из туннеля.
    ///
    /// Мерить первым запросом нельзя: в него входит подъём соединения — TCP, TLS,
    /// у VLESS ещё Reality/XHTTP, у WireGuard хендшейк. Отсюда были 900–2300 мс
    /// при реальных ~200. Поэтому сначала прогрев (он и поднимает туннель), а потом
    /// несколько запросов по уже открытому keep-alive соединению: их время и есть
    /// один RTT. Показываем минимум из проб — без случайных всплесков.
    static func ping(port: Int) async -> Int? {
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        // Одно соединение на хост: иначе URLSession откроет второе и мы снова
        // намерим хендшейк вместо задержки.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = proxySettings(port: port)
        let session = URLSession(configuration: configuration)

        // Прогрев: поднимаем туннель и TLS. Его время в замер не входит.
        guard (try? await session.data(from: url)) != nil else { return nil }

        // Четыре пробы вместо трёх: у WireTurn первая после простоя всё ещё может
        // включать пересборку SRTP-сессии, и минимум из четырёх её срезает.
        var best: Int?
        for _ in 0..<4 {
            let clock = Date()
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty
            else { continue }
            let millis = Int(Date().timeIntervalSince(clock) * 1000)
            if millis > 0 { best = min(best ?? millis, millis) }
        }
        session.invalidateAndCancel()
        return best
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

    /// Короткая подпись страны: флаг + ISO-код («🇩🇪 DE»). Нужна там, где важна одна строка.
    static func shortCountry(code: String?) -> String? {
        guard let code, code.count == 2 else { return nil }
        let flag = self.flag(code)
        return flag.isEmpty ? code.uppercased() : "\(flag) \(code.uppercased())"
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

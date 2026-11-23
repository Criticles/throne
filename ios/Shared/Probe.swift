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

    /// Пинг как в клиентах: один RTT через туннель.
    ///
    /// TCP-CONNECT через прокси даёт минимум два круга (хендшейк протокола + соединение до цели),
    /// а hysteria2 вообще отвечает сразу, ещё ничего не отправив — отсюда «0 мс».
    /// Поэтому меряем UDP: SOCKS5 `UDP ASSOCIATE` + DNS-запрос к 1.1.1.1 — ровно один круг.
    static func ping(port: Int) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let udp = blockingUdpPing(port: port)
                if let udp, udp > 0 {
                    continuation.resume(returning: udp)
                    return
                }
                // Транспорт без UDP-релея (редкость) — остаётся TCP-замер, но нули не показываем.
                let tcp = blockingSocksRTT(port: port, host: "1.1.1.1", targetPort: 443)
                continuation.resume(returning: (tcp ?? 0) > 10 ? tcp : nil)
            }
        }
    }

    // MARK: - UDP-пинг через SOCKS5

    private static func blockingUdpPing(port: Int) -> Int? {
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        guard tcp >= 0 else { return nil }
        defer { close(tcp) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(tcp, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard writeAll(tcp, [0x05, 0x01, 0x00]), readExactly(tcp, 2) != nil else { return nil }

        // UDP ASSOCIATE — прокси отвечает адресом своего UDP-релея.
        guard writeAll(tcp, [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
              let head = readExactly(tcp, 4), head[0] == 0x05, head[1] == 0x00
        else { return nil }

        var relayHost = "127.0.0.1"
        var relayPort: UInt16 = 0
        switch head[3] {
        case 0x01:
            guard let raw = readExactly(tcp, 6) else { return nil }
            var addr = in_addr()
            raw[0..<4].withUnsafeBytes { addr = $0.load(as: in_addr.self) }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
            relayHost = String(cString: buffer)
            relayPort = UInt16(raw[4]) << 8 | UInt16(raw[5])
        case 0x04:
            guard let raw = readExactly(tcp, 18) else { return nil }
            var addr = in6_addr()
            raw[0..<16].withUnsafeBytes { addr = $0.load(as: in6_addr.self) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
            relayHost = String(cString: buffer)
            relayPort = UInt16(raw[16]) << 8 | UInt16(raw[17])
        default:
            return nil
        }
        guard relayPort != 0 else { return nil }
        if relayHost == "0.0.0.0" || relayHost == "::" { relayHost = "127.0.0.1" }

        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        guard udp >= 0 else { return nil }
        defer { close(udp) }
        setsockopt(udp, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var relay = sockaddr_in()
        relay.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        relay.sin_family = sa_family_t(AF_INET)
        relay.sin_port = relayPort.bigEndian
        relay.sin_addr.s_addr = inet_addr(relayHost)

        // SOCKS5 UDP-заголовок: RSV(2) FRAG(1) ATYP(1) 1.1.1.1:53 + DNS-запрос.
        var packet: [UInt8] = [0x00, 0x00, 0x00, 0x01, 1, 1, 1, 1, 0x00, 0x35]
        packet.append(contentsOf: dnsQuery())

        let clock = Date()
        let sent = packet.withUnsafeBufferPointer { bytes in
            withUnsafePointer(to: &relay) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udp, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        var reply = [UInt8](repeating: 0, count: 2048)
        let got = recv(udp, &reply, reply.count, 0)
        guard got > 0 else { return nil }
        return Int(Date().timeIntervalSince(clock) * 1000)
    }

    /// Минимальный DNS-запрос A для example.com — один круг, без TLS и без кэша.
    private static func dnsQuery() -> [UInt8] {
        var bytes: [UInt8] = [0x1a, 0x2b, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in ["example", "com"] {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: Array(label.utf8))
        }
        bytes.append(0x00)
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return bytes
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

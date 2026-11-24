import Foundation
import SwiftUI

/// Куда пускать трафик, если правило сработало.
enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case proxy, direct, block

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxy: return "Через VPN"
        case .direct: return "Напрямую"
        case .block: return "Блокировать"
        }
    }
}

/// На чём правило построено. Набор как в sing-box/Xray: домен и его варианты, IP-сеть,
/// списки geosite/geoip, приложения.
enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case suffix, domain, keyword, ipCIDR, geosite, geoip, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suffix: return "Домен и поддомены"
        case .domain: return "Точный домен"
        case .keyword: return "Слово в адресе"
        case .ipCIDR: return "IP или подсеть"
        case .geosite: return "Список geosite"
        case .geoip: return "Страна geoip"
        case .app: return "Приложение"
        }
    }

    var placeholder: String {
        switch self {
        case .suffix, .domain: return "example.com"
        case .keyword: return "ads"
        case .ipCIDR: return "10.0.0.0/8"
        case .geosite: return "category-ads-all"
        case .geoip: return "ru"
        case .app: return "com.apple.Safari"
        }
    }

    var hint: String {
        switch self {
        case .suffix: return "Сработает на самом домене и любом поддомене."
        case .domain: return "Только точное совпадение."
        case .keyword: return "Любая часть адреса — удобно для рекламных сетей."
        case .ipCIDR: return "Один адрес или подсеть в формате CIDR."
        case .geosite: return "Тег из geosite.dat: cn, category-games, google…"
        case .geoip: return "Двухбуквенный код страны из geoip.dat."
        case .app: return "Идентификатор приложения (только в сборке через Network Extension)."
        }
    }
}

/// Одно правило маршрутизации.
struct RouteRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: RuleKind = .suffix
    var value: String = ""
    var action: RuleAction = .proxy
    var enabled = true
    /// Встроенные правила (локальная сеть, российские адреса) не удаляем, только выключаем.
    var builtin = false

    var title: String {
        switch kind {
        case .geosite: return "geosite:" + value
        case .geoip: return "geoip:" + value
        case .app: return value
        default: return value
        }
    }
}

/// Набор правил по URL: sing-box `rule_set` (бинарный .srs) или текстовый список доменов.
struct RuleSet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    /// `binary` — .srs/.dat от sing-box, `source` — текстовый список доменов.
    var format: String = "binary"
    var updated: Date?
    var bytes: Int = 0
    var autoUpdate = true
    var intervalHours = 24

    static let presets: [RuleSet] = [
        RuleSet(name: "geosite-ru", url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-ru.srs"),
        RuleSet(name: "geosite-ads", url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"),
        RuleSet(name: "geoip-ru", url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"),
    ]
}

/// Запись расширенной маршрутизации: правило либо принудительный outbound.
struct RoutePlanEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    /// `rule` — условие, `outbound` — принудительная цель.
    var kind = "rule"
    /// Атрибут условия: domain, domain_suffix, rule_set, process_name…
    var attr = "domain"
    var value = ""

    var title: String {
        kind == "outbound" ? "Outbound: " + value : attr + ": " + value
    }

    init(id: UUID = UUID(), kind: String = "rule", attr: String = "domain", value: String = "") {
        self.id = id
        self.kind = kind
        self.attr = attr
        self.value = value
    }

    /// Планы, сохранённые до появления `attr`, должны читаться: поля необязательные.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try container.decodeIfPresent(String.self, forKey: .kind)) ?? "rule"
        attr = (try container.decodeIfPresent(String.self, forKey: .attr)) ?? "domain"
        value = (try container.decodeIfPresent(String.self, forKey: .value)) ?? ""
    }
}

/// Атрибуты маршрутизации, которые понимает sing-box. В интерфейсе показываем
/// сначала те, которыми реально пользуются (порядок = популярность).
enum RouteAttribute {
    static let all: [String] = [
        "domain", "domain_suffix", "domain_keyword", "domain_regex",
        "rule_set", "process_name", "package_name", "protocol", "network",
        "ip_cidr", "source_ip_cidr", "source_ip_is_private", "ip_is_private",
        "port", "port_range", "source_port", "source_port_range",
        "inbound", "wifi_ssid", "wifi_bssid", "process_path", "process_path_regex",
        "ip_version", "invert",
    ]

    static func hint(_ attr: String) -> String {
        switch attr {
        case "domain": return "точный домен: claude.ai"
        case "domain_suffix": return "домен и поддомены: example.com"
        case "domain_keyword": return "слово в домене: ads"
        case "domain_regex": return "регулярное выражение по домену"
        case "rule_set": return "набор: geosite-ru, geoip-ru, geosite-spotify@ads"
        case "process_name": return "имя процесса: Telegram.exe"
        case "package_name": return "пакет Android: org.telegram.messenger"
        case "protocol": return "dns, http, tls, bittorrent"
        case "network": return "tcp или udp"
        case "ip_cidr": return "получатель: 10.0.0.0/8"
        case "source_ip_cidr": return "источник: 192.168.0.0/16"
        case "source_ip_is_private": return "true — источник из локальной сети"
        case "ip_is_private": return "true — получатель локальный"
        case "port": return "порт: 443 или 443,8443"
        case "port_range": return "диапазон: 1000:2000"
        case "source_port": return "порт источника"
        case "source_port_range": return "диапазон портов источника"
        case "inbound": return "тег входящего соединения"
        case "wifi_ssid": return "имя Wi-Fi сети"
        case "wifi_bssid": return "BSSID сети"
        case "process_path": return "путь к процессу"
        case "process_path_regex": return "регулярное выражение по пути"
        case "ip_version": return "4 или 6"
        case "invert": return "true — инвертировать условие"
        default: return ""
        }
    }
}

/// План маршрутизации: что делать по умолчанию и список записей по порядку.
/// Формат совпадает с тем, что понимает сборка через Network Extension.
struct RoutePlan: Codable {
    var name = "Маршрут"
    var finalTarget = "proxy"
    var entries: [RoutePlanEntry] = []
    /// Упрощённый вид: четыре списка доменов, как в Throne на ПК.
    var directList = ""
    var proxyList = ""
    var blockList = ""
    var warpList = ""

    init(name: String = "Маршрут", finalTarget: String = "proxy",
         entries: [RoutePlanEntry] = [], directList: String = "",
         proxyList: String = "", blockList: String = "", warpList: String = "") {
        self.name = name
        self.finalTarget = finalTarget
        self.entries = entries
        self.directList = directList
        self.proxyList = proxyList
        self.blockList = blockList
        self.warpList = warpList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try container.decodeIfPresent(String.self, forKey: .name)) ?? "Маршрут"
        finalTarget = (try container.decodeIfPresent(String.self, forKey: .finalTarget)) ?? "proxy"
        entries = (try container.decodeIfPresent([RoutePlanEntry].self, forKey: .entries)) ?? []
        directList = (try container.decodeIfPresent(String.self, forKey: .directList)) ?? ""
        proxyList = (try container.decodeIfPresent(String.self, forKey: .proxyList)) ?? ""
        blockList = (try container.decodeIfPresent(String.self, forKey: .blockList)) ?? ""
        warpList = (try container.decodeIfPresent(String.self, forKey: .warpList)) ?? ""
    }
}

/// Скачанный список: geoip.dat / geosite.dat.
struct GeoAsset: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    var bytes: Int = 0
    var updated: Date?

    static let all: [GeoAsset] = [
        GeoAsset(id: "geoip",
                 name: "geoip.dat",
                 url: "https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geoip.dat"),
        GeoAsset(id: "geosite",
                 name: "geosite.dat",
                 url: "https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geosite.dat"),
    ]
}

/// Правила маршрутизации и гео-списки. Хранится в UserDefaults, файлы — в Application Support.
@MainActor
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [RouteRule] = []
    @Published private(set) var assets: [GeoAsset] = GeoAsset.all
    @Published private(set) var ruleSets: [RuleSet] = []
    @Published private(set) var plan = RoutePlan()
    @Published private(set) var status = ""

    private let rulesKey = "rules.items"
    private let setsKey = "rules.sets"
    private let planKey = "rules.plan"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    // MARK: - Правила

    func add(_ rule: RouteRule) {
        var rule = rule
        rule.value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.value.isEmpty else { return }
        rules.append(rule)
        save()
        status = "правило добавлено: \(rule.title)"
    }

    func update(_ rule: RouteRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func delete(_ rule: RouteRule) {
        guard !rule.builtin else { return }
        rules.removeAll { $0.id == rule.id }
        save()
    }

    func toggle(_ rule: RouteRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].enabled.toggle()
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Проверка «какое правило поймает этот адрес» — с учётом порядка, как у ядра.
    /// Возвращает описание результата для экрана статистики.
    func evaluate(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return "введите домен или адрес" }

        for rule in rules where rule.enabled {
            switch rule.kind {
            case .suffix:
                let value = rule.value.lowercased()
                if text == value || text.hasSuffix("." + value) {
                    return "→ \(rule.action.title) по правилу «\(rule.value)» (домен и поддомены)"
                }
            case .domain:
                if text == rule.value.lowercased() {
                    return "→ \(rule.action.title) по правилу «\(rule.value)» (точный домен)"
                }
            case .keyword:
                if text.contains(rule.value.lowercased()) {
                    return "→ \(rule.action.title) по правилу «\(rule.value)» (слово в адресе)"
                }
            case .ipCIDR:
                if Self.matchesCIDR(text, rule.value) {
                    return "→ \(rule.action.title) по правилу «\(rule.value)» (подсеть)"
                }
            case .geosite:
                return "→ \(rule.action.title) по списку geosite:\(rule.value) — точный ответ даст ядро: списки читает оно"
            case .geoip:
                return "→ \(rule.action.title) по стране geoip:\(rule.value) — определяется только в ядре"
            case .app:
                return "→ \(rule.action.title) по приложению \(rule.value) — работает в сборке через Network Extension"
            }
        }
        return "→ напрямую: ни одно правило не совпало"
    }

    /// Простое совпадение IPv4/подсети — для подсказки в интерфейсе, не для маршрутизации.
    private static func matchesCIDR(_ text: String, _ cidr: String) -> Bool {
        if !cidr.contains("/") { return text == cidr.lowercased() }
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        let host = ipToInt(String(parts[0])) ?? 0
        guard let address = ipToInt(text) else { return false }
        guard bits > 0, bits <= 32 else { return host == address }
        let mask: UInt32 = bits == 32 ? 0xFFFFFFFF : (0xFFFFFFFF << (32 - UInt32(bits)))
        return (host & mask) == (address & mask)
    }

    private static func ipToInt(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".")
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard let value = UInt32(octet), value <= 255 else { return nil }
            result = (result << 8) | value
        }
        return result
    }

    // MARK: - Подсказки при вводе правила

    /// Каталог популярных тегов: подсказываем то, что реально встречается в списках.
    static let geositeTags: [String] = [
        "geolocation-!cn", "geolocation-ru", "cn", "ru", "category-ads-all", "category-ads",
        "category-games", "category-media", "category-social-media-ru", "category-porn",
        "apple", "google", "google-scholar", "youtube", "telegram", "github", "gitlab",
        "openai", "anthropic", "netflix", "spotify", "discord", "twitch", "steam", "epicgames",
        "microsoft", "meta", "twitter", "instagram", "tiktok", "whatsapp", "cloudflare",
        "cloudfront", "amazon", "ebay", "paypal", "binance", "booking", "speedtest", "dropbox",
        "slack", "notion", "figma", "adobe", "jetbrains", "unity", "vk", "yandex", "mailru",
        "ok", "ozon", "wildberries", "kinopoisk", "ivi", "sber", "tinkoff", "gosuslugi",
    ]

    static let geoipCodes: [String] = [
        "ru", "de", "fi", "ee", "lv", "lt", "pl", "se", "no", "dk", "nl", "be", "fr", "it",
        "es", "pt", "ch", "at", "cz", "sk", "hu", "ro", "bg", "gr", "tr", "ua", "by", "md",
        "ge", "am", "az", "kz", "uz", "kg", "tj", "tm", "us", "ca", "gb", "ie", "jp", "kr",
        "cn", "hk", "tw", "sg", "in", "ae", "il", "br", "ar", "cl", "au", "nz", "za", "eg",
    ]

    /// Подсказки под поле ввода: теги, коды стран и уже добавленные значения.
    func suggestions(for kind: RuleKind, query: String) -> [String] {
        let base: [String]
        switch kind {
        case .geosite: base = Self.geositeTags
        case .geoip: base = Self.geoipCodes + Self.geoipCodes.map { $0.uppercased() }
        case .app:
            base = ["com.apple.Safari", "com.apple.MobileSMS", "com.telegram.Telegram-iOS",
                    "com.google.chrome.ios", "ru.yandex.mobile.browser", "com.spotify.client"]
        case .suffix, .domain:
            base = rules.map { $0.value }
        case .keyword:
            base = ["ads", "tracker", "banner", "doubleclick", "analytics", "metrics"]
        case .ipCIDR:
            base = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8"]
        }

        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unique = Array(Set(base)).sorted()
        guard !text.isEmpty else { return Array(unique.prefix(12)) }
        return unique.filter { $0.lowercased().contains(text) }.prefix(12).map { $0 }
    }

    // MARK: - Расширенная маршрутизация

    func savePlan(_ plan: RoutePlan) {
        self.plan = plan
        if let data = try? JSONEncoder().encode(plan) {
            defaults.set(data, forKey: planKey)
        }
        status = "план маршрутизации сохранён"
    }

    func planJSON(_ plan: RoutePlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func applyPlanJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(RoutePlan.self, from: data)
        else { return false }
        savePlan(parsed)
        return true
    }

    // MARK: - Свои гео-списки

    func addAsset(name: String, url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = GeoAsset(id: "custom-" + String(UUID().uuidString.prefix(6)),
                             name: title.isEmpty ? "мой-список" : title,
                             url: trimmed)
        assets.append(asset)
        saveAssets()
        status = "список добавлен: " + asset.name
        Task { await download(asset) }
    }

    // MARK: - Наборы правил по URL

    func addRuleSet(_ set: RuleSet) {
        guard !ruleSets.contains(where: { $0.url == set.url }) else {
            status = "такой набор уже добавлен"
            return
        }
        ruleSets.append(set)
        saveSets()
        Task { await download(set) }
    }

    func deleteRuleSet(_ set: RuleSet) {
        ruleSets.removeAll { $0.id == set.id }
        if let url = fileURL(for: set) { try? FileManager.default.removeItem(at: url) }
        saveSets()
    }

    func download(_ set: RuleSet) async {
        guard let url = URL(string: set.url), let target = fileURL(for: set) else { return }
        status = "скачиваю " + set.name + "…"
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                status = set.name + ": сервер ответил " + String((response as? HTTPURLResponse)?.statusCode ?? -1)
                return
            }
            try data.write(to: target, options: .atomic)
            if let index = ruleSets.firstIndex(where: { $0.id == set.id }) {
                ruleSets[index].bytes = data.count
                ruleSets[index].updated = Date()
            }
            saveSets()
            status = set.name + " обновлён: " + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        } catch {
            status = set.name + ": " + error.localizedDescription
        }
    }

    /// Обновляем устаревшие наборы — вызывается при запуске приложения.
    func autoUpdateIfNeeded() async {
        let now = Date()
        for set in ruleSets where set.autoUpdate {
            if let updated = set.updated,
               now.timeIntervalSince(updated) < TimeInterval(max(set.intervalHours, 1) * 3600) { continue }
            await download(set)
        }
    }

    private func saveSets() {
        guard let data = try? JSONEncoder().encode(ruleSets) else { return }
        defaults.set(data, forKey: setsKey)
    }

    // MARK: - Гео-списки

    private static var rulesDirectory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let directory = base.appendingPathComponent("rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func fileURL(for asset: GeoAsset) -> URL? {
        Self.rulesDirectory?.appendingPathComponent(asset.name)
    }

    func fileURL(for set: RuleSet) -> URL? {
        let tail = URL(string: set.url)?.lastPathComponent ?? (set.name + ".srs")
        return Self.rulesDirectory?.appendingPathComponent(set.name + "-" + tail)
    }

    /// Скачивает список и запоминает размер с датой. Сами списки читает ядро, не приложение.
    func download(_ asset: GeoAsset) async {
        status = "скачиваю \(asset.name)…"
        guard let url = URL(string: asset.url), let fileURL = fileURL(for: asset) else {
            status = "некорректный адрес \(asset.name)"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                status = "\(asset.name): сервер ответил \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            try data.write(to: fileURL, options: .atomic)
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                assets[index].bytes = data.count
                assets[index].updated = Date()
            }
            saveAssets()
            status = "\(asset.name) обновлён: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        } catch {
            status = "\(asset.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Хранение

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: rulesKey)
    }

    private func saveAssets() {
        var snapshot: [[String: String]] = []
        for asset in assets {
            snapshot.append([
                "id": asset.id,
                "name": asset.name,
                "url": asset.url,
                "bytes": String(asset.bytes),
                "updated": String(asset.updated?.timeIntervalSince1970 ?? 0),
            ])
        }
        defaults.set(snapshot, forKey: "rules.assets")
    }

    private func load() {
        if let data = defaults.data(forKey: rulesKey),
           let stored = try? JSONDecoder().decode([RouteRule].self, from: data) {
            rules = stored
        }
        if rules.isEmpty {
            rules = [
                RouteRule(kind: .ipCIDR, value: "10.0.0.0/8", action: .direct, builtin: true),
                RouteRule(kind: .ipCIDR, value: "172.16.0.0/12", action: .direct, builtin: true),
                RouteRule(kind: .ipCIDR, value: "192.168.0.0/16", action: .direct, builtin: true),
                RouteRule(kind: .geosite, value: "geolocation-ru", action: .direct, builtin: true),
                RouteRule(kind: .geosite, value: "category-ads-all", action: .block, builtin: true),
            ]
            save()
        }
        if let data = defaults.data(forKey: setsKey),
           let stored = try? JSONDecoder().decode([RuleSet].self, from: data) {
            ruleSets = stored
        }
        if let data = defaults.data(forKey: planKey),
           let stored = try? JSONDecoder().decode(RoutePlan.self, from: data) {
            plan = stored
        }
        if let stored = defaults.array(forKey: "rules.assets") as? [[String: String]] {
            for item in stored {
                guard let id = item["id"] else { continue }
                let bytes = Int(item["bytes"] ?? "") ?? 0
                let stamp = Double(item["updated"] ?? "") ?? 0
                let updated = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
                if let index = assets.firstIndex(where: { $0.id == id }) {
                    assets[index].bytes = bytes
                    assets[index].updated = updated
                } else if let url = item["url"], !url.isEmpty {
                    // Свой список, добавленный пользователем: восстанавливаем из хранилища.
                    assets.append(GeoAsset(id: id,
                                           name: item["name"] ?? id,
                                           url: url,
                                           bytes: bytes,
                                           updated: updated))
                }
            }
        }
    }
}

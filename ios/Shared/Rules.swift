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
        RuleSet(name: "geosite-ru", url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"),
        RuleSet(name: "geosite-ads", url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"),
        RuleSet(name: "geoip-ru", url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"),
    ]
}

/// Атрибут внутри папки: имя и значения. В JSON Throne это `"domain": ["a", "b"]`.
struct RoutePlanAttr: Codable, Identifiable, Hashable {
    var id = UUID()
    var attr: String = "domain"
    var values: [String] = []

    init(id: UUID = UUID(), attr: String = "domain", values: [String] = []) {
        self.id = id
        self.attr = attr
        self.values = values
    }

    var summary: String {
        values.isEmpty ? "не задано" : values.joined(separator: ", ")
    }
}

/// Ключ для разбора произвольных полей: формат Throne кладёт атрибуты прямо в объект правила.
struct AnyAttributeKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    init(_ name: String) { self.stringValue = name }
}

/// Папка с атрибутами — это одно правило маршрутизации.
///
/// Так устроен документ настольного Throne: у правила есть `name`, `action`, `outbound`,
/// а условия лежат полями рядом (`domain`, `rule_set`, `process_name`…). Поэтому «куда пускать»
/// принадлежит папке, а не каждому атрибуту — иначе outbound дублировался бы в каждой строке.
///
/// Порядок папок важен: сверху — то, что сработает первым.
struct RoutePlanRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "Правило"
    /// `route` — направить в outbound, `reject` — заблокировать.
    var action: String = "route"
    /// Куда пускать: proxy / direct / reject / имя сервера.
    var outbound: String = "proxy"
    var attrs: [RoutePlanAttr] = []
    /// Служебная папка «Быстрых правил»: удалить нельзя, выход фиксирован.
    var locked = false

    init(id: UUID = UUID(), name: String = "Правило", action: String = "route",
         outbound: String = "proxy", attrs: [RoutePlanAttr] = [], locked: Bool = false) {
        self.id = id
        self.name = name
        self.action = action
        self.outbound = outbound
        self.locked = locked
        // `outbound` — такой же атрибут папки, как остальные: держим его в списке сразу,
        // иначе новая папка показывала «0 атрибутов», хотя выход у неё уже задан.
        var list = attrs
        if !list.contains(where: { $0.attr == "outbound" }) {
            list.insert(RoutePlanAttr(attr: "outbound", values: [outbound]), at: 0)
        }
        self.attrs = list
    }

    /// Подпись строки папки: «proxy · 3 атрибута» или «блокировать · 1 атрибут».
    var subtitle: String {
        let destination = action == "reject" ? "блокировать" : outbound
        let count = attrs.count
        let word: String
        switch count % 100 {
        case 11...14: word = "атрибутов"
        default:
            switch count % 10 {
            case 1: word = "атрибут"
            case 2...4: word = "атрибута"
            default: word = "атрибутов"
            }
        }
        return destination + " · " + String(count) + " " + word
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyAttributeKey.self)

        if let text = try? container.decode(String.self, forKey: AnyAttributeKey("id")),
           let uuid = UUID(uuidString: text) {
            id = uuid
        } else if let uuid = try? container.decode(UUID.self, forKey: AnyAttributeKey("id")) {
            id = uuid
        }
        name = (try container.decodeIfPresent(String.self, forKey: AnyAttributeKey("name"))) ?? "Правило"
        locked = (try container.decodeIfPresent(Bool.self, forKey: AnyAttributeKey("locked"))) ?? false
        action = (try container.decodeIfPresent(String.self, forKey: AnyAttributeKey("action"))) ?? "route"
        outbound = (try container.decodeIfPresent(String.self, forKey: AnyAttributeKey("outbound")))
            ?? (action == "reject" ? "reject" : "proxy")

        // Наш прежний вид хранил атрибуты вложенным массивом объектов.
        var collected: [RoutePlanAttr] = []
        if let nested = try? container.decode([RoutePlanAttr].self, forKey: AnyAttributeKey("attrs")) {
            collected = nested
        }
        // Формат Throne: атрибуты — это остальные ключи объекта (массив, строка или bool).
        let service = ["id", "name", "action", "outbound", "type", "attrs", "v", "locked"]
        for key in container.allKeys where !service.contains(key.stringValue) {
            if let values = try? container.decode([String].self, forKey: key) {
                collected.append(RoutePlanAttr(attr: key.stringValue, values: values))
            } else if let numbers = try? container.decode([Int].self, forKey: key) {
                // Мы пишем `port` числами — читаем обратно строками, как их правит редактор.
                collected.append(RoutePlanAttr(attr: key.stringValue, values: numbers.map(String.init)))
            } else if let flags = try? container.decode([Bool].self, forKey: key) {
                collected.append(RoutePlanAttr(attr: key.stringValue,
                                               values: flags.map { $0 ? "true" : "false" }))
            } else if let single = try? container.decode(String.self, forKey: key) {
                collected.append(RoutePlanAttr(attr: key.stringValue, values: [single]))
            } else if let flag = try? container.decode(Bool.self, forKey: key) {
                collected.append(RoutePlanAttr(attr: key.stringValue, values: [flag ? "true" : "false"]))
            } else if let number = try? container.decode(Int.self, forKey: key) {
                collected.append(RoutePlanAttr(attr: key.stringValue, values: [String(number)]))
            }
        }
        // Порядок атрибутов — как в справочнике, а не как лёг JSON: так список читается.
        attrs = collected.enumerated().sorted { left, right in
            let a = RouteAttribute.all.firstIndex(of: left.element.attr) ?? Int.max
            let b = RouteAttribute.all.firstIndex(of: right.element.attr) ?? Int.max
            return a == b ? left.offset < right.offset : a < b
        }.map { $0.element }
    }

    /// Пишем ровно тот же документ, что отдаёт настольный Throne: `action` + `outbound` +
    /// поля-атрибуты массивами. Один формат на импорт и экспорт — меньше шансов разойтись.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyAttributeKey.self)
        try container.encode("custom", forKey: AnyAttributeKey("type"))
        try container.encode(name, forKey: AnyAttributeKey("name"))
        try container.encode(action, forKey: AnyAttributeKey("action"))
        if action != "reject" {
            try container.encode(outbound, forKey: AnyAttributeKey("outbound"))
        }
        try container.encode(id.uuidString, forKey: AnyAttributeKey("id"))
        for item in attrs where !item.values.isEmpty && item.attr != "outbound" {
            // Типы — как ждёт ядро: числа числами, булевы true/false, остальное строкой
            // или массивом, как в документе Throne. Строки вида "443"/"true" ядро
            // отвергает: `cannot unmarshal string into Go value of type uint16`.
            if let value = RouteAttribute.jsonValue(item.attr, item.values) {
                try Self.encode(value, into: &container, key: item.attr)
            }
        }
    }

    private static func encode(_ value: Any,
                               into container: inout KeyedEncodingContainer<AnyAttributeKey>,
                               key: String) throws {
        switch value {
        case let numbers as [Int]:
            try container.encode(numbers, forKey: AnyAttributeKey(key))
        case let list as [String]:
            try container.encode(list, forKey: AnyAttributeKey(key))
        case let number as Int:
            try container.encode(number, forKey: AnyAttributeKey(key))
        case let flag as Bool:
            try container.encode(flag, forKey: AnyAttributeKey(key))
        case let text as String:
            try container.encode(text, forKey: AnyAttributeKey(key))
        default:
            break
        }
    }
}

/// Запись старого формата (профиль → плоский список записей). Читается только для миграции.
struct RoutePlanEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    /// `rule` — условие, `outbound` — принудительная цель.
    var kind = "rule"
    /// Атрибут условия: domain, domain_suffix, rule_set, process_name…
    var attr = "domain"
    var value = ""
    /// Куда направить совпадение: proxy / direct / reject / имя сервера.
    var target: String? = nil

    var title: String {
        if kind == "outbound" { return "Outbound: " + value }
        let destination = target ?? "proxy"
        return attr + ": " + value + " → " + destination
    }

    init(id: UUID = UUID(), kind: String = "rule", attr: String = "domain",
         value: String = "", target: String? = nil) {
        self.id = id
        self.kind = kind
        self.attr = attr
        self.value = value
        self.target = target
    }

    /// Планы, сохранённые до появления новых полей, должны читаться: они необязательные.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try container.decodeIfPresent(String.self, forKey: .kind)) ?? "rule"
        attr = (try container.decodeIfPresent(String.self, forKey: .attr)) ?? "domain"
        value = (try container.decodeIfPresent(String.self, forKey: .value)) ?? ""
        target = try container.decodeIfPresent(String.self, forKey: .target)
    }
}

/// Атрибуты маршрутизации, которые понимает sing-box. Порядок — как в настольном клиенте:
/// пользователь ищет глазами знакомый список, а не алфавит.
enum RouteAttribute {
    static let all: [String] = [
        "ip_version", "network", "protocol", "inbound",
        "domain", "domain_suffix", "domain_keyword", "domain_regex",
        "source_ip_cidr", "source_ip_is_private", "ip_cidr", "ip_is_private",
        "source_port", "source_port_range", "port", "port_range",
        "process_name", "process_path", "process_path_regex", "package_name",
        "wifi_ssid", "wifi_bssid", "rule_set", "invert",
        "outbound", "override_address", "override_port",
        "tls_spoof", "tls_spoof_method", "method", "no_drop",
    ]

    /// Что атрибут делает — одна фраза, её показываем прямо под значением в папке.
    static func about(_ attr: String) -> String {
        switch attr {
        case "ip_version": return "версия адреса: 4 или 6"
        case "network": return "тип соединения: tcp или udp"
        case "protocol": return "протокол поверх TCP/UDP: dns, tls, quic, stun"
        case "inbound": return "какой вход ядра принял соединение: mixed-in, tun-in"
        case "domain": return "точный домен, без поддоменов"
        case "domain_suffix": return "домен и все его поддомены"
        case "domain_keyword": return "слово внутри домена: ads поймает ads.example.com"
        case "domain_regex": return "регулярное выражение по домену"
        case "source_ip_cidr": return "адрес или подсеть источника"
        case "source_ip_is_private": return "true — запрос из локальной сети"
        case "ip_cidr": return "адрес или подсеть получателя"
        case "ip_is_private": return "true — получатель в локальной сети"
        case "source_port": return "порт источника"
        case "source_port_range": return "диапазон портов источника: 1000:2000"
        case "port": return "порт получателя: 443 или 443,8443"
        case "port_range": return "диапазон портов получателя"
        case "rule_set": return "готовый набор geosite/geoip, который читает ядро"
        case "invert": return "true — инвертировать условие"
        case "outbound": return "куда направить: proxy, direct, reject или конкретный сервер"
        case "override_address": return "подменить адрес назначения"
        case "override_port": return "подменить порт назначения"
        case "tls_spoof": return "подмена TLS для обхода блокировок"
        case "tls_spoof_method": return "способ подмены: wrong-sequence, wrong-checksum, wrong-ack…"
        case "method": return "ответ на reject: default, drop, reply"
        case "no_drop": return "true — не отбрасывать пакеты, а отвечать на них"
        default: return ""
        }
    }

    /// Значения выбираются из готового списка: в этих полях опечатка ломает правило.
    static let enumerated: Set<String> = [
        "network", "protocol", "ip_version", "inbound", "rule_set", "outbound",
        "ip_is_private", "source_ip_is_private", "invert", "no_drop",
        "tls_spoof_method", "method", "ip_version",
    ]

    static func needsChoice(_ attr: String) -> Bool {
        enumerated.contains(attr)
    }

    /// Атрибуты, у которых копится несколько значений (наборы правил). Остальные
    /// перечислимые — одно значение: второй выбор снимает первый.
    static let multiple: Set<String> = ["rule_set"]

    static func singleChoice(_ attr: String) -> Bool {
        enumerated.contains(attr) && !multiple.contains(attr)
    }

    /// Атрибуты, которых на iPhone нет: ядро не видит процессы, Android-пакеты и имя Wi-Fi,
    /// поэтому правило с ними молча не срабатывает. В редакторе их не предлагаем,
    /// а из импортированного профиля выкидываем.
    static let unavailable: Set<String> = [
        "process_name", "process_path", "process_path_regex",
        "package_name", "wifi_ssid", "wifi_bssid",
    ]

    /// Что можно показать в списке атрибутов на этой платформе.
    static var available: [String] { all.filter { !unavailable.contains($0) } }

    /// Папка без условий бесполезна — только `outbound` её не спасает: правило без условий
    /// поймает всё. Возвращаем nil, если после чистки условий не осталось.
    static func sanitized(_ rule: RoutePlanRule) -> RoutePlanRule? {
        var rule = rule
        rule.attrs.removeAll { unavailable.contains($0.attr) }
        // Атрибуты, которых нет в справочнике (импорт из более новой версии настольного
        // клиента, старые сохранения), ядро не поймёт — их не держим.
        rule.attrs.removeAll { !RouteAttribute.all.contains($0.attr) }
        // Старые папки сохранялись без атрибута outbound — добавляем, чтобы счётчик и
        // редактор показывали одинаково.
        if !rule.attrs.contains(where: { $0.attr == "outbound" }) {
            rule.attrs.insert(RoutePlanAttr(attr: "outbound",
                                            values: [rule.outbound.isEmpty ? "proxy" : rule.outbound]),
                              at: 0)
        }
        let conditions = rule.attrs.filter { $0.attr != "outbound" }
        // Служебные папки «Быстрых правил» живут всегда: пустые они просто
        // не попадают в конфиг (ядро не получает правило без условий).
        if rule.locked { return rule }
        return conditions.isEmpty ? nil : rule
    }

    /// Значение атрибута в JSON нужного типа.
    static func jsonValue(_ attr: String, _ values: [String]) -> Any? {
        let cleaned = values
            .flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        if attr == "ip_version" { return Int(cleaned[0]) }
        if Self.integerAttributes.contains(attr) {
            let numbers = cleaned.compactMap { Int($0) }
            return numbers.isEmpty ? nil : numbers
        }
        if Self.booleanAttributes.contains(attr) {
            let lower = cleaned[0].lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
            return nil
        }
        if Self.scalarAttributes.contains(attr) { return cleaned[0] }
        return cleaned
    }

    /// Числа в JSON: ядро ждёт `uint16`/`int`, а не строку.
    static let integerAttributes: Set<String> = ["port", "source_port", "override_port"]

    /// Булевы в JSON.
    static let booleanAttributes: Set<String> = [
        "invert", "no_drop", "ip_is_private", "source_ip_is_private",
    ]

    /// Одиночная строка, а не список (так пишет и настольный Throne).
    static let scalarAttributes: Set<String> = [
        "protocol", "network", "inbound", "method", "tls_spoof",
        "tls_spoof_method", "override_address",
    ]

    /// Варианты для кнопки «Выбрать». Пусто — значит атрибут пишется текстом.
    static func options(_ attr: String) -> [String] {
        switch attr {
        // Значения — ровно те, что перечислены в enum закреплённого ядра:
        // иначе оно падает с `unknown reject method` / `unknown method`.
        case "network": return ["tcp", "udp", "icmp"]
        case "protocol": return ["dns", "http", "tls", "quic", "stun", "bittorrent", "dtls", "ssh", "rdp", "ntp"]
        case "ip_version": return ["4", "6"]
        case "inbound": return ["mixed-in", "tun-in"]
        case "ip_is_private", "source_ip_is_private", "invert", "no_drop": return ["true", "false"]
        case "tls_spoof_method":
            return ["wrong-sequence", "wrong-checksum", "wrong-ack", "wrong-md5", "wrong-timestamp"]
        case "method": return ["default", "drop", "reply"]
        case "outbound": return ["proxy", "direct", "reject"]
        case "rule_set":
            return RouteCatalog.geositeTags.map { "geosite-" + $0 } + RouteCatalog.geoipCodes.map { "geoip-" + $0 }
        default: return []
        }
    }

    /// Подсказки под полем ввода: что писать, пока пользователь не запомнил формат.
    static func hint(_ attr: String) -> String {
        switch attr {
        case "domain": return "точный домен: claude.ai"
        case "domain_suffix": return "домен и поддомены: example.com"
        case "domain_keyword": return "слово в домене: ads"
        case "domain_regex": return "регулярное выражение по домену"
        case "rule_set": return "набор: geosite-ru, geoip-ru, geosite-spotify"
        case "process_name": return "имя процесса: Telegram.exe"
        case "process_path": return "путь к процессу"
        case "process_path_regex": return "регулярное выражение по пути"
        case "package_name": return "пакет Android: org.telegram.messenger"
        case "protocol": return "dns, http, tls, quic, stun, bittorrent"
        case "network": return "tcp или udp"
        case "ip_cidr": return "получатель: 10.0.0.0/8"
        case "source_ip_cidr": return "источник: 192.168.0.0/16"
        case "source_ip_is_private": return "true — источник из локальной сети"
        case "ip_is_private": return "true — получатель локальный"
        case "port": return "порт: 443 или 443,8443"
        case "port_range": return "диапазон: 1000:2000"
        case "source_port": return "порт источника"
        case "source_port_range": return "диапазон портов источника"
        case "inbound": return "тег входящего соединения: mixed-in"
        case "wifi_ssid": return "имя Wi-Fi сети"
        case "wifi_bssid": return "BSSID сети"
        case "ip_version": return "4 или 6"
        case "invert": return "true — инвертировать условие"
        case "outbound": return "куда направить: proxy, direct, reject или сервер"
        case "override_address": return "подменить адрес назначения"
        case "override_port": return "подменить порт назначения"
        case "tls_spoof": return "подмена TLS (для обхода блокировок)"
        case "tls_spoof_method": return "какой сбой подделывать: wrong-sequence, wrong-checksum, wrong-ack…"
        case "method": return "как ответить на reject: default, drop, reply"
        case "no_drop": return "true — не отбрасывать пакеты"
        default: return ""
        }
    }

    /// Быстрая подсказка «нужен ли выбор» — для кнопки в строке записи.
    static func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "не задано" : trimmed
    }
}

/// Профиль маршрутизации: что делать по умолчанию и папки с атрибутами по порядку.
/// Профилей может быть несколько; активный применяется к ядру.
struct RoutePlan: Codable, Identifiable {
    var id = UUID()
    var name = "Маршрут"
    /// Служебный профиль «Быстрые правила»: всегда активен, удалить нельзя,
    /// своего final не имеет — непойманное уходит в выбранный профиль.
    var isSystem = false
    var finalTarget = "proxy"
    /// Папки с атрибутами. Порядок = порядок применения, первая сверху срабатывает первой.
    var rules: [RoutePlanRule] = []
    /// Упрощённый вид: четыре списка доменов, как в Throne на ПК.
    var directList = ""
    var proxyList = ""
    var blockList = ""
    var warpList = ""
    var updated: Date?

    init(id: UUID = UUID(), name: String = "Маршрут", isSystem: Bool = false, finalTarget: String = "proxy",
         rules: [RoutePlanRule] = [], directList: String = "",
         proxyList: String = "", blockList: String = "", warpList: String = "",
         updated: Date? = nil) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.finalTarget = finalTarget
        self.rules = rules
        self.directList = directList
        self.proxyList = proxyList
        self.blockList = blockList
        self.warpList = warpList
        self.updated = updated
    }

    private enum Keys: String, CodingKey {
        case id, name, isSystem, finalTarget, rules, entries, directList, proxyList, blockList, warpList, updated
        case defaultOutbound = "default_outbound"
        case kind, v
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let text = try? container.decode(String.self, forKey: .id),
           let uuid = UUID(uuidString: text) {
            id = uuid
        } else {
            id = (try container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        }
        name = (try container.decodeIfPresent(String.self, forKey: .name)) ?? "Маршрут"
        isSystem = (try container.decodeIfPresent(Bool.self, forKey: .isSystem)) ?? false
        // Документ Throne зовёт это `default_outbound`, наш прежний вид — `finalTarget`.
        // Отдельные строки: `try` внутри автозамыкания `??` компилятор не пропускает.
        let storedTarget = try container.decodeIfPresent(String.self, forKey: .finalTarget)
        let throneTarget = try container.decodeIfPresent(String.self, forKey: .defaultOutbound)
        finalTarget = storedTarget ?? throneTarget ?? "proxy"
        if let stored = try container.decodeIfPresent([RoutePlanRule].self, forKey: .rules) {
            rules = stored
        } else if let legacy = try container.decodeIfPresent([RoutePlanEntry].self, forKey: .entries) {
            // Старый вид: плоский список записей. Каждая становится своей папкой с тем же
            // именем, что было у атрибута, — данные не теряются, порядок сохраняется.
            rules = legacy.map { entry in
                // Запись «принудительный outbound» — это не атрибут, а сама цель папки:
                // иначе в JSON получился бы ключ `outbound` со значением массивом.
                if entry.attr == "outbound" {
                    return RoutePlanRule(name: Self.legacyName(entry),
                                         action: (entry.value == "reject") ? "reject" : "route",
                                         outbound: entry.value.isEmpty ? "proxy" : entry.value,
                                         attrs: [])
                }
                return RoutePlanRule(name: Self.legacyName(entry),
                                     action: (entry.target == "reject") ? "reject" : "route",
                                     outbound: entry.target ?? "proxy",
                                     attrs: [RoutePlanAttr(attr: entry.attr, values: [entry.value])])
            }
        }
        directList = (try container.decodeIfPresent(String.self, forKey: .directList)) ?? ""
        proxyList = (try container.decodeIfPresent(String.self, forKey: .proxyList)) ?? ""
        blockList = (try container.decodeIfPresent(String.self, forKey: .blockList)) ?? ""
        warpList = (try container.decodeIfPresent(String.self, forKey: .warpList)) ?? ""
        updated = try container.decodeIfPresent(Date.self, forKey: .updated)
    }

    /// Экспортируем тот же документ, что понимает настольный Throne:
    /// `kind`, `v`, `default_outbound`, `rules[]`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode("throne-route-profile", forKey: .kind)
        try container.encode(1, forKey: .v)
        try container.encode(id.uuidString, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(finalTarget, forKey: .defaultOutbound)
        try container.encode(rules, forKey: .rules)
        if !directList.isEmpty { try container.encode(directList, forKey: .directList) }
        if !proxyList.isEmpty { try container.encode(proxyList, forKey: .proxyList) }
        if !blockList.isEmpty { try container.encode(blockList, forKey: .blockList) }
        if !warpList.isEmpty { try container.encode(warpList, forKey: .warpList) }
        try container.encodeIfPresent(updated, forKey: .updated)
    }

    private static func legacyName(_ entry: RoutePlanEntry) -> String {
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? entry.attr : value
    }

    func rule(with id: UUID) -> RoutePlanRule? {
        rules.first { $0.id == id }
    }

    /// Подпись профиля в списке: «по умолчанию: proxy · 6 папок».
    var summary: String {
        let folders = rules.count
        let word: String
        switch folders % 100 {
        case 11...14: word = "папок"
        default:
            switch folders % 10 {
            case 1: word = "папка"
            case 2...4: word = "папки"
            default: word = "папок"
            }
        }
        var parts = ["по умолчанию: " + finalTarget]
        parts.append(String(folders) + " " + word)
        return parts.joined(separator: " · ")
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

/// Справочники подсказок маршрутизации. Без актора: их читают и хранилище правил,
/// и редактор атрибутов (у него нет доступа к главному актору в статических вызовах).
enum RouteCatalog {
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
}

/// Правила маршрутизации и гео-списки. Хранится в UserDefaults, файлы — в Application Support.
@MainActor
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [RouteRule] = []
    @Published private(set) var assets: [GeoAsset] = GeoAsset.all
    @Published private(set) var ruleSets: [RuleSet] = []
    /// Профили маршрутизации: несколько наборов правил, применяется активный.
    @Published private(set) var plans: [RoutePlan] = []
    @Published private(set) var activePlanID: UUID?
    @Published private(set) var status = ""

    /// Активный профиль: к нему обращаются список маршрутов и редактор.
    /// Служебный профиль «Быстрые правила»: всегда активен, стоит первым.
    var quickPlan: RoutePlan? {
        plans.first { $0.isSystem }
    }

    var plan: RoutePlan {
        plans.first { $0.id == activePlanID } ?? plans.first ?? RoutePlan()
    }

    private let rulesKey = "rules.items"
    private let setsKey = "rules.sets"
    private let plansKey = "rules.plans"
    private let activePlanKey = "rules.activePlan"
    private let legacyPlanKey = "rules.plan"
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

    /// Каталоги подсказок живут в `RouteCatalog` (без актора): их читает и редактор атрибутов.
    static var geositeTags: [String] { RouteCatalog.geositeTags }
    static var geoipCodes: [String] { RouteCatalog.geoipCodes }

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

    // MARK: - Профили маршрутизации

    func plan(with id: UUID?) -> RoutePlan? {
        guard let id else { return nil }
        return plans.first { $0.id == id }
    }

    /// Новый профиль: пустой, с тем же «по умолчанию», что у активного.
    @discardableResult
    func addPlan(name: String = "Новый профиль") -> RoutePlan {
        var created = RoutePlan(name: name)
        created.finalTarget = plan.finalTarget
        created.updated = Date()
        plans.append(created)
        activePlanID = created.id
        savePlans()
        status = "профиль создан: " + created.name
        return created
    }

    @discardableResult
    func duplicatePlan(_ id: UUID) -> RoutePlan? {
        guard var copy = plan(with: id) else { return nil }
        copy.id = UUID()
        copy.name += " — копия"
        copy.updated = Date()
        plans.append(copy)
        savePlans()
        status = "профиль скопирован: " + copy.name
        return copy
    }

    /// Эталон «Быстрых правил»: три папки-выхода, которые нельзя удалить.
    static func serviceFolders() -> [RoutePlanRule] {
        [RoutePlanRule(name: "Reject", outbound: "reject", locked: true),
         RoutePlanRule(name: "Direct", outbound: "direct", locked: true),
         RoutePlanRule(name: "Proxy", outbound: "proxy", locked: true)]
    }

    static func withServiceFolders(_ plan: RoutePlan) -> RoutePlan {
        var result = plan
        for folder in serviceFolders() {
            // Если папка уже есть по имени — принудительно возвращаем ей защиту
            // и штатный выход: так старые сохранения не остаются «разлоченными».
            if let index = result.rules.firstIndex(where: { $0.name == folder.name }) {
                result.rules[index].locked = true
                result.rules[index].outbound = folder.outbound
                result.rules[index].action = folder.action
                continue
            }
            result.rules.insert(folder, at: 0)
        }
        return result
    }

    /// Создаёт служебный профиль при первом запуске и чинит его, если он потерялся.
    private func ensureQuickPlan() {
        if let index = plans.firstIndex(where: { $0.isSystem }) {
            plans[index] = Self.withServiceFolders(plans[index])
            return
        }
        let quick = Self.withServiceFolders(
            RoutePlan(name: "Быстрые правила", isSystem: true, finalTarget: "proxy"))
        plans.insert(quick, at: 0)
    }

    func savePlan(_ plan: RoutePlan) {
        var updated = plan
        updated.updated = Date()
        if updated.isSystem { updated = Self.withServiceFolders(updated) }
        if let index = plans.firstIndex(where: { $0.id == updated.id }) {
            plans[index] = updated
        } else {
            plans.append(updated)
        }
        activePlanID = updated.id
        savePlans()
        status = "профиль сохранён: " + updated.name
    }

    func activate(_ id: UUID) {
        guard plans.contains(where: { $0.id == id }) else { return }
        activePlanID = id
        defaults.set(id.uuidString, forKey: activePlanKey)
        status = "активный профиль: " + plan.name
    }

    func deletePlan(_ id: UUID) {
        // «Быстрые правила» удалять нельзя ни из списка, ни из редактора:
        // на них держится маршрутизация соединений. Проверяем и по флагу,
        // и по имени — на случай старых сохранений без isSystem.
        if let plan = plans.first(where: { $0.id == id }),
           plan.isSystem || plan.name == "Быстрые правила" {
            status = "служебный профиль удалить нельзя"
            return
        }
        plans.removeAll { $0.id == id }
        if plans.isEmpty { plans = [RoutePlan(name: "Default")] }
        if activePlanID == id { activePlanID = plans.first?.id }
        savePlans()
        status = "профиль удалён"
    }

    func renamePlan(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[index].name = trimmed
        plans[index].updated = Date()
        savePlans()
    }

    /// Добавить значение в атрибут конкретной папки конкретного профиля — из «Соединений»
    /// или из редактора. Если такого атрибута в папке ещё нет, он создаётся.
    @discardableResult
    func addValue(_ value: String, attr: String, to planID: UUID, ruleID: UUID) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let planIndex = plans.firstIndex(where: { $0.id == planID }),
              let ruleIndex = plans[planIndex].rules.firstIndex(where: { $0.id == ruleID })
        else { return false }

        // `outbound` — не атрибут папки, а её цель: пишем в поле, а не в JSON-ключ.
        if attr == "outbound" {
            plans[planIndex].rules[ruleIndex].outbound = trimmed
            plans[planIndex].rules[ruleIndex].action = trimmed == "reject" ? "reject" : "route"
        } else if let attrIndex = plans[planIndex].rules[ruleIndex].attrs.firstIndex(where: { $0.attr == attr }) {
            if !plans[planIndex].rules[ruleIndex].attrs[attrIndex].values.contains(trimmed) {
                plans[planIndex].rules[ruleIndex].attrs[attrIndex].values.append(trimmed)
            }
        } else {
            plans[planIndex].rules[ruleIndex].attrs.append(RoutePlanAttr(attr: attr, values: [trimmed]))
        }
        plans[planIndex].updated = Date()
        savePlans()
        let folder = plans[planIndex].rules[ruleIndex].name
        status = "«\(trimmed)» добавлено в «\(folder)» профиля «\(plans[planIndex].name)»"
        return true
    }

    /// Новая папка с атрибутами в конце списка (значит, сработает последней).
    @discardableResult
    func addRule(named name: String, to planID: UUID) -> RoutePlanRule? {
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = RoutePlanRule(name: title.isEmpty ? "Правило" : title)
        plans[index].rules.append(rule)
        plans[index].updated = Date()
        savePlans()
        return rule
    }

    // MARK: - Импорт и экспорт

    /// JSON профиля — он же предпросмотр.
    func planJSON(_ plan: RoutePlan) -> String {
        RouteCodec.encode(plan)
    }

    /// Ссылка Throne: `throne://route?plan=<процент-кодированный JSON>`.
    func planLink(_ plan: RoutePlan) -> String {
        RouteCodec.link(plan)
    }

    /// Импорт: сам понимает, JSON в буфере или ссылка Throne.
    @discardableResult
    func importPlan(from text: String) -> RoutePlan? {
        guard var imported = RouteCodec.decode(text) else {
            status = "не разобрать: нужен JSON профиля или ссылка throne://route"
            return nil
        }
        imported.id = UUID()
        imported.updated = Date()
        if imported.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            imported.name = "Импортированный"
        }
        let clean = Self.sanitize(imported)
        plans.append(clean)
        activePlanID = clean.id
        savePlans()
        status = "профиль импортирован: " + clean.name
        return clean
    }

    /// Импорт из настольного клиента приносит атрибуты, которых на iOS нет (процессы,
    /// Android-пакеты, Wi-Fi), и папки, которые держатся только на них. Такую папку не
    /// оставляем: без условий она поймала бы весь трафик.
    private static func sanitize(_ plan: RoutePlan) -> RoutePlan {
        var plan = plan
        let before = plan.rules.count
        plan.rules = plan.rules.compactMap(RouteAttribute.sanitized)
        let dropped = before - plan.rules.count
        if dropped > 0 {
            LogStore.shared.append("маршрут «\(plan.name)»: убрано папок без условий на iOS — \(dropped)", stamp: false)
        }
        return plan
    }

    private func savePlans() {
        if let data = try? JSONEncoder().encode(plans) {
            defaults.set(data, forKey: plansKey)
        }
        if let activePlanID {
            defaults.set(activePlanID.uuidString, forKey: activePlanKey)
        }
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
            status = set.name + " обновлён: " + Format.size(Int64(data.count))
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

    /// Имена скачанных наборов → локальный путь. Ядро читает файл само, поэтому в конфиг
    /// попадают только те наборы, чей файл уже лежит на диске.
    func ruleSetPaths() -> [String: String] {
        var paths: [String: String] = [:]
        for set in ruleSets {
            guard let url = fileURL(for: set),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            paths[set.name] = url.path
        }
        return paths
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
            status = "\(asset.name) обновлён: \(Format.size(Int64(data.count)))"
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
        loadPlans()
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

    /// Профили маршрутизации: массив + активный. Старый одиночный план (`rules.plan`)
    /// переносится в профили при первом запуске новой сборки.
    private func loadPlans() {
        if let data = defaults.data(forKey: plansKey),
           let stored = try? JSONDecoder().decode([RoutePlan].self, from: data),
           !stored.isEmpty {
            plans = stored.map(Self.sanitize)
        }
        if plans.isEmpty {
            if let data = defaults.data(forKey: legacyPlanKey),
               let legacy = try? JSONDecoder().decode(RoutePlan.self, from: data) {
                plans = [Self.sanitize(legacy)]
            } else {
                plans = [RoutePlan(name: "Default")]
            }
        }
        // В настольном Throne профиль по умолчанию зовётся Default — переименовываем
        // наш прежний единственный профиль, чтобы список начинался с него.
        if plans.count == 1, plans[0].name == "По правилам" {
            plans[0].name = "Default"
        }
        ensureQuickPlan()
        if let raw = defaults.string(forKey: activePlanKey), let id = UUID(uuidString: raw),
           plans.contains(where: { $0.id == id }) {
            activePlanID = id
        } else {
            activePlanID = plans.first?.id
        }
        savePlans()
    }
}

/// Кодирование профиля маршрутизации: JSON и ссылка `throne://route`.
/// Импорт сам понимает, что лежит в буфере — JSON, ссылка с `?plan=` или base64 от JSON.
enum RouteCodec {
    /// Документ профиля без наших служебных полей: ровно то, что пишет настольный клиент.
    private static func exportObject(_ plan: RoutePlan) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let raw = try? encoder.encode(plan),
              var object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        // `id` нужен только нашему хранилищу: в документе Throne его нет. Дату обновления
        // тоже не выносим — это наша служебная пометка.
        object.removeValue(forKey: "id")
        object.removeValue(forKey: "updated")
        if var rules = object["rules"] as? [[String: Any]] {
            for index in rules.indices {
                rules[index].removeValue(forKey: "id")
                // Пустые атрибуты не пишем: они означают «ещё не заполнено».
                let emptyKeys = rules[index].keys.filter {
                    (rules[index][$0] as? [String])?.isEmpty == true
                }
                for key in emptyKeys {
                    rules[index].removeValue(forKey: key)
                }
            }
            object["rules"] = rules
        }
        return object
    }

    static func encode(_ plan: RoutePlan) -> String {
        guard let object = exportObject(plan),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Ссылка в формате настольного Throne: `throne://route/<base64url>` без переводов строк.
    static func link(_ plan: RoutePlan) -> String {
        guard let object = exportObject(plan),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "throne://route/" }
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "throne://route/" + base64
    }

    static func decode(_ raw: String) -> RoutePlan? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("throne://") { return decodeLink(text) }
        if let plan = decodeJSON(text) { return plan }
        // Иногда из чата копируют только полезную нагрузку — base64 без схемы.
        if let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
           let plan = try? JSONDecoder().decode(RoutePlan.self, from: data) {
            return plan
        }
        return nil
    }

    private static func decodeLink(_ text: String) -> RoutePlan? {
        // `throne://route?plan=<json или base64>`
        if let components = URLComponents(string: text),
           let value = components.queryItems?.first(where: { $0.name == "plan" })?.value,
           !value.isEmpty {
            if let plan = decodeJSON(value) { return plan }
            if let plan = decodeBase64(value) { return plan }
        }
        // `throne://route/<base64url>` — формат настольного клиента.
        if let components = URLComponents(string: text) {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty, let plan = decodeBase64(path) { return plan }
        }
        // Хвост после «throne://route/», если URLComponents не справился с экзотикой.
        if let range = text.range(of: "route/") {
            let tail = String(text[range.upperBound...])
            if let plan = decodeBase64(tail) { return plan }
        }
        return nil
    }

    private static func decodeJSON(_ text: String) -> RoutePlan? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RoutePlan.self, from: data)
    }

    private static func decodeBase64(_ text: String) -> RoutePlan? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return decodeJSON(json)
    }
}

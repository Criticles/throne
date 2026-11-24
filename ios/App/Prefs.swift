import SwiftUI

/// Настройки, которые живут на стороне приложения. Ядро читает их по мере появления
/// поддержки: сейчас честно влияет только выбор Xray-профилей и MTU.
@MainActor
final class Prefs: ObservableObject {
    enum RoutingMode: String, CaseIterable, Identifiable {
        case rules, global, direct

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rules: return "По правилам"
            case .global: return "Всё в VPN"
            case .direct: return "Напрямую"
            }
        }

        var hint: String {
            switch self {
            case .rules: return "Локальная сеть и российские адреса идут мимо туннеля, остальное — через сервер."
            case .global: return "Весь трафик идёт через выбранный сервер."
            case .direct: return "Туннель поднят, но трафик идёт как обычно — чтобы сравнить."
            }
        }
    }

    enum XrayPreference: String, CaseIterable, Identifiable {
        case xhttpOnly, xhttpAndReality, allVLESS

        var id: String { rawValue }

        var title: String {
            switch self {
            case .xhttpOnly: return "Только XHTTP"
            case .xhttpAndReality: return "XHTTP и Reality"
            case .allVLESS: return "Все VLESS"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, ping, country, kind

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "По имени"
            case .ping: return "По пингу"
            case .country: return "По стране"
            case .kind: return "По протоколу"
            }
        }
    }

    enum DNSMode: String, CaseIterable, Identifiable {
        case system, doh, dot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "Системный"
            case .doh: return "DoH"
            case .dot: return "DoT"
            }
        }

        var hint: String {
            switch self {
            case .system: return "Резолвер провайдера. Быстро, но ответы могут подменяться."
            case .doh: return "DNS поверх HTTPS — не подменяется по пути."
            case .dot: return "DNS поверх TLS на 853-м порту."
            }
        }
    }

    enum TUNStack: String, CaseIterable, Identifiable {
        case gvisor, system, mixed

        var id: String { rawValue }
        var title: String { rawValue }
    }

    private let defaults = UserDefaults.standard

    @Published var routingMode: RoutingMode {
        didSet { defaults.set(routingMode.rawValue, forKey: "prefs.routing") }
    }
    @Published var bypassLocalNetwork: Bool {
        didSet { defaults.set(bypassLocalNetwork, forKey: "prefs.bypassLAN") }
    }
    @Published var blockAds: Bool {
        didSet { defaults.set(blockAds, forKey: "prefs.blockAds") }
    }
    @Published var xrayPreference: XrayPreference {
        didSet { defaults.set(xrayPreference.rawValue, forKey: "prefs.xray") }
    }
    @Published var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: "prefs.sort") }
    }
    @Published var favoriteFirst: Bool {
        didSet { defaults.set(favoriteFirst, forKey: "prefs.favoriteFirst") }
    }
    /// Автовыбор быстрейшего сервера после параллельного пинга.
    @Published var autoFastest: Bool {
        didSet { defaults.set(autoFastest, forKey: "prefs.autoFastest") }
    }
    /// Финальный outbound: куда идёт всё, что не поймало ни одно правило.
    @Published var finalAction: RuleAction {
        didSet { defaults.set(finalAction.rawValue, forKey: "prefs.finalAction") }
    }
    @Published var dnsMode: DNSMode {
        didSet { defaults.set(dnsMode.rawValue, forKey: "prefs.dnsMode") }
    }
    @Published var dnsServer: String {
        didSet { defaults.set(dnsServer, forKey: "prefs.dnsServer") }
    }
    @Published var tunStack: TUNStack {
        didSet { defaults.set(tunStack.rawValue, forKey: "prefs.tunStack") }
    }
    @Published var tunMTU: Int {
        didSet { defaults.set(tunMTU, forKey: "prefs.tunMTU") }
    }
    @Published var ipv6: Bool {
        didSet { defaults.set(ipv6, forKey: "prefs.ipv6") }
    }
    /// Напоминание за 3 дня до конца подписки (локальное уведомление).
    @Published var notifyExpiry: Bool {
        didSet { defaults.set(notifyExpiry, forKey: "prefs.notifyExpiry") }
    }
    /// Что именно дёргаем при пинге: лёгкий адрес без TLS отвечает быстрее.
    @Published var pingTarget: String {
        didSet { defaults.set(pingTarget, forKey: "prefs.pingTarget") }
    }
    @Published var speedURL: String {
        didSet { defaults.set(speedURL, forKey: "prefs.speedURL") }
    }
    @Published var speedUploadURL: String {
        didSet { defaults.set(speedUploadURL, forKey: "prefs.speedUploadURL") }
    }
    @Published var speedMegabytes: Int {
        didSet { defaults.set(speedMegabytes, forKey: "prefs.speedMB") }
    }

    init() {
        routingMode = RoutingMode(rawValue: defaults.string(forKey: "prefs.routing") ?? "") ?? .rules
        bypassLocalNetwork = defaults.object(forKey: "prefs.bypassLAN") as? Bool ?? true
        blockAds = defaults.object(forKey: "prefs.blockAds") as? Bool ?? false
        xrayPreference = XrayPreference(rawValue: defaults.string(forKey: "prefs.xray") ?? "") ?? .xhttpAndReality
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "prefs.sort") ?? "") ?? .name
        favoriteFirst = defaults.object(forKey: "prefs.favoriteFirst") as? Bool ?? true
        autoFastest = defaults.object(forKey: "prefs.autoFastest") as? Bool ?? false
        finalAction = RuleAction(rawValue: defaults.string(forKey: "prefs.finalAction") ?? "") ?? .proxy
        dnsMode = DNSMode(rawValue: defaults.string(forKey: "prefs.dnsMode") ?? "") ?? .system
        dnsServer = defaults.string(forKey: "prefs.dnsServer") ?? "https://1.1.1.1/dns-query"
        tunStack = TUNStack(rawValue: defaults.string(forKey: "prefs.tunStack") ?? "") ?? .gvisor
        let storedMTU = defaults.integer(forKey: "prefs.tunMTU")
        tunMTU = storedMTU == 0 ? 9000 : storedMTU
        ipv6 = defaults.object(forKey: "prefs.ipv6") as? Bool ?? true
        notifyExpiry = defaults.object(forKey: "prefs.notifyExpiry") as? Bool ?? true
        pingTarget = defaults.string(forKey: "prefs.pingTarget") ?? "http://cp.cloudflare.com/generate_204"
        speedURL = defaults.string(forKey: "prefs.speedURL") ?? "https://speed.cloudflare.com/__down"
        speedUploadURL = defaults.string(forKey: "prefs.speedUploadURL") ?? "https://speed.cloudflare.com/__up"
        let storedMB = defaults.integer(forKey: "prefs.speedMB")
        speedMegabytes = storedMB == 0 ? 10 : storedMB
    }
}

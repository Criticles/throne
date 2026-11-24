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

    init() {
        routingMode = RoutingMode(rawValue: defaults.string(forKey: "prefs.routing") ?? "") ?? .rules
        bypassLocalNetwork = defaults.object(forKey: "prefs.bypassLAN") as? Bool ?? true
        blockAds = defaults.object(forKey: "prefs.blockAds") as? Bool ?? false
        xrayPreference = XrayPreference(rawValue: defaults.string(forKey: "prefs.xray") ?? "") ?? .xhttpAndReality
        sortOrder = SortOrder(rawValue: defaults.string(forKey: "prefs.sort") ?? "") ?? .name
    }
}

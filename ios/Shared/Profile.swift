import Foundation

enum ProfileKind: String, Codable, CaseIterable {
    case vless
    case hysteria2
    case mieru
    case wireguard
    case wireturn

    var title: String {
        switch self {
        case .vless: return "VLESS"
        case .hysteria2: return "Hysteria2"
        case .mieru: return "Mieru"
        case .wireguard: return "WireGuard"
        case .wireturn: return "Turnable + WG"
        }
    }
}

/// Профиль: то, из чего генерируется конфиг sing-box.
/// `payload` — исходная share-ссылка либо JSON подписки (для wireturn).
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ProfileKind
    var payload: String
    /// Почему профиль может не заработать в текущей сборке (например, нет движка Turnable).
    var note: String?
}

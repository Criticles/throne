import Foundation

enum ProfileKind: String, Codable, CaseIterable {
    case vless
    case xray
    case hysteria2
    case mieru
    case wireguard
    case wireturn
    case turnable
    case custom

    var title: String {
        switch self {
        case .vless: return "VLESS"
        case .xray: return "VLESS XHTTP (Xray)"
        case .hysteria2: return "Hysteria2"
        case .mieru: return "Mieru"
        case .wireguard: return "WireGuard / AWG"
        case .wireturn: return "WireTurn"
        case .turnable: return "Turnable"
        case .custom: return "JSON подписки"
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
    /// Протокол для бейджа: имя сервера не трогаем, протокол показываем отдельно.
    var badge: String? = nil
    /// Папка в списке — подписка, из которой пришёл сервер (nil = добавлен вручную).
    var group: String? = nil
    /// Избранное: держим наверху списка.
    var favorite = false
    /// Заметка пользователя к серверу.
    var note: String? = nil
}

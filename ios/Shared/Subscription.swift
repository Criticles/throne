import Foundation

/// Подписка — «папка» серверов: ссылка панели и всё, что из неё пришло.
struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var updated: Date?
    var count: Int = 0

    /// Автообновление по таймеру: проверяем при запуске и пока приложение открыто.
    var autoUpdate: Bool = true
    var intervalHours: Int = 12

    /// Из заголовка `subscription-userinfo`: срок и израсходованный трафик.
    var expire: Date?
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0

    var used: Int64 { upload + download }

    /// «12,3 ГБ из 100 ГБ · до 14.12.2026» или «без ограничений».
    var trafficText: String {
        let usedText = Self.size(used)
        if total > 0 {
            return usedText + " из " + Self.size(total)
        }
        return total == 0 ? usedText + " · без ограничений" : usedText
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

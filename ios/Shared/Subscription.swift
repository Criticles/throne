import Foundation

/// Подписка — «папка» серверов: одна ссылка панели и всё, что из неё пришло.
struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var updated: Date?
    var count: Int = 0
}

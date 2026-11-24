import Foundation

/// Папка серверов. Имя — только подпись: папок с одинаковыми именами может быть сколько угодно,
/// поэтому всё держится на `id`, а не на названии (раньше папка = имя подписки, и вторую такую
/// же папку создать было нельзя).
struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Когда создана — только для порядка в списке.
    var created = Date()

    init(id: UUID = UUID(), name: String, created: Date = Date()) {
        self.id = id
        self.name = name
        self.created = created
    }

    /// Папки, сохранённые до появления `created`, должны читаться.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try container.decodeIfPresent(String.self, forKey: .name)) ?? "Папка"
        created = (try container.decodeIfPresent(Date.self, forKey: .created)) ?? Date()
    }
}

import Foundation

/// Единый журнал: импорт подписки, ядро sing-box и Turnable пишут в один поток.
/// Раньше это были два разных блока — приходилось прыгать между ними и склеивать руками.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var text = ""

    /// Ограничение, чтобы длинный лог не съел память приложения.
    private let limit = 600_000

    func append(_ line: String, stamp: Bool = true) {
        let entry = stamp ? "[\(Self.formatter.string(from: Date()))] \(line)" : line
        text += entry + "\n"
        if text.count > limit {
            text = String(text.suffix(limit / 2))
        }
    }

    func clear() {
        text = ""
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

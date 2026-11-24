import Foundation

/// Единый журнал: импорт подписки, ядро sing-box и Turnable пишут в один поток.
/// Раньше это были два разных блока — приходилось прыгать между ними и склеивать руками.
///
/// Строки копятся в буфере и выкладываются пачкой: ядро на старте пишет сотни строк в секунду,
/// а обновление `@Published` на каждую из них подвешивало экран журнала — он выглядел пустым,
/// пока его не очистишь.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var text = ""

    /// Ограничение, чтобы длинный лог не съел память приложения.
    private let limit = 400_000
    /// Буфер непринятых строк и признак уже запланированной выкладки.
    private var pending = ""
    private var flushScheduled = false

    func append(_ line: String, stamp: Bool = true) {
        let entry = stamp ? "[\(Self.formatter.string(from: Date()))] \(line)" : line
        pending += entry + "\n"
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.flush()
        }
    }

    /// Выложить накопленное в `text` — одно обновление вместо сотни.
    func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var next = text + pending
        pending = ""
        if next.count > limit {
            next = String(next.suffix(limit / 2))
        }
        text = next
    }

    func clear() {
        pending = ""
        flushScheduled = false
        text = ""
    }

    /// Хвост журнала для показа: `Text` на сотнях килобайт подвисает, а свежее — внизу.
    func tail(_ lines: Int = 600) -> String {
        var snapshot = text + pending
        if snapshot.isEmpty { return "" }
        let parts = snapshot.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.count > lines {
            snapshot = parts.suffix(lines).joined(separator: "\n")
        }
        return snapshot
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

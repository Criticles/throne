import Foundation

/// Простейший лог в App Group: расширение пишет, приложение читает.
/// Отдельный файл выбран специально — network-extension не может держать UI,
/// а обмен сообщениями `handleAppMessage` теряет строки при остановке туннеля.
enum TunnelLog {
    private static let queue = DispatchQueue(label: "throne.tunnel.log")

    static func write(_ line: String) {
        guard let url = Shared.logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let text = "[\(stamp)] \(line)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func read() -> String {
        guard let url = Shared.logURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func clear() {
        guard let url = Shared.logURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}

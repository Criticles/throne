import Foundation

/// Накопительная статистика трафика по профилям и дням.
/// Источник — Clash API `/traffic`; данные кладём в UserDefaults, чтобы пережить перезапуск.
@MainActor
final class TrafficStatsStore: ObservableObject {
    struct Row: Codable, Identifiable, Hashable {
        var key: String
        var day: String
        var profile: String
        var up: Int64
        var down: Int64
        var id: String { key }
    }

    @Published private(set) var rows: [Row] = []

    static let shared = TrafficStatsStore()

    private let storageKey = "traffic.rows"

    init() {
        load()
    }

    func record(profile: String, up: Int64, down: Int64) {
        guard up > 0 || down > 0 else { return }
        let day = Self.dayFormatter.string(from: Date())
        let key = day + "|" + profile
        if let index = rows.firstIndex(where: { $0.key == key }) {
            rows[index].up += up
            rows[index].down += down
        } else {
            rows.append(Row(key: key, day: day, profile: profile, up: up, down: down))
        }
        save()
    }

    /// Сводка за последние N дней: по профилю, отсортировано по расходу.
    func summary(days: Int) -> [Row] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: Date()) ?? Date()
        let limit = Self.dayFormatter.string(from: cutoff)
        var grouped: [String: Row] = [:]
        for row in rows where row.day >= limit {
            if var existing = grouped[row.profile] {
                existing.up += row.up
                existing.down += row.down
                grouped[row.profile] = existing
            } else {
                grouped[row.profile] = Row(key: row.profile, day: row.day, profile: row.profile,
                                           up: row.up, down: row.down)
            }
        }
        return grouped.values.sorted { ($0.up + $0.down) > ($1.up + $1.down) }
    }

    /// Расход за всё время по одному профилю.
    func total(profile: String) -> (up: Int64, down: Int64) {
        var up: Int64 = 0
        var down: Int64 = 0
        for row in rows where row.profile == profile {
            up += row.up
            down += row.down
        }
        return (up, down)
    }

    func clear() {
        rows = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([Row].self, from: data) {
            rows = stored
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Живой трафик из Clash API: `/traffic` — вебсокет, по одному срезу в секунду.
/// Рисуем последние 60 секунд — этого хватает, чтобы видеть «дышит» туннель или нет.
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var down: [Double] = []
    @Published private(set) var up: [Double] = []
    @Published private(set) var speedDown: Double = 0
    @Published private(set) var speedUp: Double = 0
    @Published private(set) var live = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var lastUpTotal: Int64 = 0
    private var lastDownTotal: Int64 = 0
    /// Намерение держать поток: если сокет отвалился (ядро перезапустили
    /// замеры пинга), переподключаемся, а не умираем до следующего подключения.
    private var shouldRun = false
    private static let lastUpKey = "traffic.lastUpTotal"
    private static let lastDownKey = "traffic.lastDownTotal"

    private var profile = ""

    func start(profile: String) {
        stop()
        self.profile = profile
        self.shouldRun = true
        // Базу берём из прошлого запуска: иначе при перезапуске монитора первый же
        // срез записывал весь объём сессии заново (двойной учёт).
        let saved = UserDefaults.standard
        self.lastUpTotal = Int64(saved.double(forKey: Self.lastUpKey))
        self.lastDownTotal = Int64(saved.double(forKey: Self.lastDownKey))
        guard let url = URL(string: "ws://127.0.0.1:\(ClashApi.port)/traffic") else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        live = true
        task.resume()
        listen(task)
    }

    func stop() {
        shouldRun = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        live = false
        speedUp = 0
        speedDown = 0
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.listen(task)
                case .failure:
                    self.live = false
                    self.reconnect()
                }
            }
        }
    }

    /// Переподключение через две секунды, пока поток нужен.
    private func reconnect() {
        guard shouldRun else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.shouldRun, !self.live, !self.profile.isEmpty else { return }
            self.start(profile: self.profile)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else { return }

        let upRate = (object["up"] as? Double) ?? Double(object["up"] as? Int ?? 0)
        let downRate = (object["down"] as? Double) ?? Double(object["down"] as? Int ?? 0)

        speedUp = upRate
        speedDown = downRate
        up.append(upRate)
        if up.count > 60 { up.removeFirst(up.count - 60) }
        down.append(downRate)
        if down.count > 60 { down.removeFirst(down.count - 60) }

        // Накопительные счётчики — из них считаем расход по профилю.
        if let totalUp = object["upTotal"] as? Double,
           let totalDown = object["downTotal"] as? Double {
            let upInt = Int64(totalUp)
            let downInt = Int64(totalDown)
            // Ядро начали заново — счётчики начинаются с нуля: берём их за базу,
            // а не считаем отрицательным приростом.
            if upInt < lastUpTotal || downInt < lastDownTotal {
                lastUpTotal = upInt
                lastDownTotal = downInt
                return
            }
            let deltaUp = upInt - lastUpTotal
            let deltaDown = downInt - lastDownTotal
            lastUpTotal = upInt
            lastDownTotal = downInt
            UserDefaults.standard.set(Double(upInt), forKey: Self.lastUpKey)
            UserDefaults.standard.set(Double(downInt), forKey: Self.lastDownKey)
            TrafficStatsStore.shared.record(profile: profile, up: deltaUp, down: deltaDown)
        }
    }

}

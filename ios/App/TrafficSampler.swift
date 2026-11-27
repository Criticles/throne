import Foundation

/// Сбор статистики трафика вне экранов: тикает всё время, пока приложение живо.
/// Раньше этим занимался экран «Соединения», поэтому при закрытой вкладке данные
/// не копились, а цифры в «Серверах» и «Соединениях» расходились (там был websocket).
@MainActor
final class TrafficSampler: ObservableObject {
    static let shared = TrafficSampler()

    /// История для графика: 10 минут плюс запас.
    @Published private(set) var samples: [TrafficSample] = []
    /// Трафик с момента включения ядра (с учётом перезапусков).
    @Published private(set) var sessionDown: Int64 = 0
    @Published private(set) var sessionUp: Int64 = 0
    /// Скорость «на данный момент» — единственный источник для обеих вкладок.
    @Published private(set) var currentDown: Double = 0
    @Published private(set) var currentUp: Double = 0

    private weak var engine: DevEngine?
    private var task: Task<Void, Never>?

    private var coreDown: Int64 = 0
    private var coreUp: Int64 = 0
    private var baseDown: Int64 = 0
    private var baseUp: Int64 = 0
    private var prevDown: Int64 = 0
    private var prevUp: Int64 = 0
    private var prevAt: Date?

    func attach(engine: DevEngine) {
        self.engine = engine
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard let engine else { return }
        let running = engine.running
        let snapshot = running
            ? await ClashApi.snapshot()
            : (list: [ClashApi.Connection](), totals: ClashApi.Totals())
        let now = Date()

        if running {
            let totals = snapshot.totals
            if totals.download < coreDown || totals.upload < coreUp {
                // Ядро перезапустилось (замеры пинга пересобирают конфиг): накопленное не теряем.
                baseDown += coreDown
                baseUp += coreUp
            }
            coreDown = totals.download
            coreUp = totals.upload
            sessionDown = baseDown + coreDown
            sessionUp = baseUp + coreUp
        }

        let deltaDown = max(sessionDown - prevDown, 0)
        let deltaUp = max(sessionUp - prevUp, 0)
        let elapsed = prevAt.map { now.timeIntervalSince($0) } ?? 0

        if prevAt == nil {
            // Первая точка: скорость неизвестна, ставим ноль — иначе всплеск на старте.
            append(at: now, down: 0, up: 0, bytesDown: 0, bytesUp: 0)
        } else if elapsed > 0.5, elapsed < 10 {
            let down = Double(deltaDown) / elapsed
            let up = Double(deltaUp) / elapsed
            currentDown = down
            currentUp = up
            append(at: now, down: down, up: up, bytesDown: deltaDown, bytesUp: deltaUp)
            // Учёт «за всё время» по профилю — здесь же, без отдельного websocket.
            if running, let name = engine.activeName, deltaDown + deltaUp > 0 {
                TrafficStatsStore.shared.record(profile: name, up: deltaUp, down: deltaDown)
            }
        } else if elapsed >= 10 {
            // Долгая пауза (приложение уходило в фон): базу сдвигаем, точку не рисуем.
            prevAt = now
            prevDown = sessionDown
            prevUp = sessionUp
            return
        }

        prevAt = now
        prevDown = sessionDown
        prevUp = sessionUp
    }

    private func append(at date: Date, down: Double, up: Double,
                        bytesDown: Int64, bytesUp: Int64) {
        samples.append(TrafficSample(at: date, down: down, up: up,
                                     bytesDown: bytesDown, bytesUp: bytesUp,
                                     totalDown: sessionDown, totalUp: sessionUp,
                                     byOutbound: [:], bytesByOutbound: [:]))
        let horizon = date.addingTimeInterval(-615)
        if let first = samples.first, first.at < horizon {
            samples.removeAll { $0.at < horizon }
        }
    }

    /// Трафик за окно — разница итогов ядра между границами окна.
    func bytes(in seconds: TimeInterval, until: Date) -> (down: Int64, up: Int64) {
        let from = until.addingTimeInterval(-seconds)
        guard let last = samples.last else { return (0, 0) }
        guard let index = samples.firstIndex(where: { $0.at >= from }) else { return (0, 0) }
        let base = index > 0 ? samples[index - 1] : samples[index]
        return (max(last.totalDown - base.totalDown, 0), max(last.totalUp - base.totalUp, 0))
    }

    func samples(in seconds: TimeInterval, until: Date) -> [TrafficSample] {
        let from = until.addingTimeInterval(-seconds)
        return samples.filter { $0.at >= from }
    }
}

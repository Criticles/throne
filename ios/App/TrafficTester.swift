import Foundation
import SwiftUI

/// Прогон трафика живёт вне экрана: ушёл в «Соединения» смотреть счётчики — тест
/// продолжается. Держим состояние в общем объекте, а экран только показывает его.
@MainActor
final class TrafficTester: ObservableObject {
    static let shared = TrafficTester()

    @Published private(set) var running = false
    @Published private(set) var downloaded: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var note = ""

    private var task: Task<Void, Never>?
    private var started = Date()

    var averageRate: Double {
        elapsed > 0 ? Double(downloaded) / elapsed : 0
    }

    var progress: Double {
        total > 0 ? min(Double(downloaded) / Double(total), 1) : 0
    }

    func start(volumeMB: Int, minutes: Int, serverID: UUID?, profile: String,
               engine: DevEngine, servers: [Profile]) {
        guard !running else { return }
        total = Int64(volumeMB) * 1024 * 1024
        downloaded = 0
        elapsed = 0
        note = "готовлю вход…"
        running = true
        started = Date()
        task = Task { [weak self] in
            await self?.run(minutes: minutes, serverID: serverID, profile: profile,
                            engine: engine, servers: servers)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if running { note = "остановлено вручную" }
        running = false
    }

    // MARK: - Работа

    private func run(minutes: Int, serverID: UUID?, profile: String,
                     engine: DevEngine, servers: [Profile]) async {
        let wanted = serverID ?? engine.activeProfileID
        var port = engine.trafficPort(for: wanted)
        if port == nil, serverID != nil {
            note = "пересобираю конфиг под выбранный сервер…"
            await engine.prepareTrafficPool(profiles: servers)
            port = engine.trafficPort(for: wanted)
        }
        guard let port else {
            note = "нет входа для этого сервера — подними ядро"
            running = false
            return
        }

        let session = Self.session(port: port)
        let rate = Double(total) / Double(max(minutes, 1) * 60)
        note = "идёт тест через " + profile

        while !Task.isCancelled, downloaded < total {
            let left = total - downloaded
            // Куски разного размера: поток не выглядит «пулемётом» одинаковых запросов.
            let chunk = min(left, Int64.random(in: 700_000...1_400_000))
            let began = Date()
            let got = await Self.fetch(chunk: chunk, session: session)
            guard !Task.isCancelled else { break }
            if got == 0 {
                note = "сервер не ответил — тест остановлен"
                break
            }
            downloaded += got
            elapsed = Date().timeIntervalSince(started)

            // Держим средний темп: спим столько, сколько «перебрали», плюс случайная добавка.
            let spent = Date().timeIntervalSince(began)
            var pause = Double(got) / rate - spent
            if pause > 0 {
                pause *= Double.random(in: 0.85...1.25)
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        elapsed = Date().timeIntervalSince(started)
        if !Task.isCancelled, downloaded >= total {
            note = "готово: " + Format.size(downloaded) + " за " + Self.clock(elapsed)
        }
        running = false
    }

    /// Один кусок через локальный вход ядра.
    private static func fetch(chunk: Int64, session: URLSession) async -> Int64 {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=" + String(chunk))
        else { return 0 }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, _) = try? await session.data(for: request) else { return 0 }
        return Int64(data.count)
    }

    /// Сессия, которая ходит не напрямую, а через локальный SOCKS ядра.
    private static func session(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": port,
        ]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

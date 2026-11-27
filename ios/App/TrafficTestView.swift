import SwiftUI

/// Тест трафика: качаем заданный объём через выбранный сервер ровно за заданное время,
/// чтобы глазами проверить счётчики («сейчас / за окно / с включения»).
///
/// Работает и в LiveContainer: там нет расширения, но ядро живёт в процессе приложения
/// (`DevPlatform`) и слушает локальный SOCKS — тест идёт через него.
struct TrafficTestView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    /// Объём теста, МБ.
    @State private var volume = 10
    /// За сколько минут этот объём прокачать.
    @State private var minutes = 1
    /// Сервер: nil — активный.
    @State private var serverID: UUID?
    @State private var running = false
    @State private var downloaded: Int64 = 0
    @State private var elapsed: TimeInterval = 0
    @State private var note = ""
    @State private var task: Task<Void, Never>?

    private var totalBytes: Int64 { Int64(volume) * 1024 * 1024 }

    private var averageRate: Double {
        elapsed > 0 ? Double(downloaded) / elapsed : 0
    }

    private var progress: Double {
        totalBytes > 0 ? min(Double(downloaded) / Double(totalBytes), 1) : 0
    }

    private var servers: [Profile] {
        store.profiles.filter { DevEngine.singboxKinds.contains($0.kind) }
    }

    private var serverTitle: String {
        guard let serverID, let profile = store.profiles.first(where: { $0.id == serverID }) else {
            return "активный" + (engine.activeName.map { " (" + $0 + ")" } ?? "")
        }
        return profile.name
    }

    var body: some View {
        Form {
            Section {
                Picker("Объём", selection: $volume) {
                    ForEach([10, 25, 50, 100], id: \.self) { value in
                        Text(String(value) + " МБ").tag(value)
                    }
                }
                Picker("За время", selection: $minutes) {
                    ForEach([1, 2, 3, 5], id: \.self) { value in
                        Text(String(value) + " мин").tag(value)
                    }
                }
                Picker("Через сервер", selection: $serverID) {
                    Text("активный").tag(UUID?.none)
                    ForEach(servers) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
            } header: {
                Text("Параметры")
            } footer: {
                Text("Трафик теста идёт через твой сервер и учитывается в его лимитах — "
                     + "как обычная загрузка. Куски и паузы рандомизированы, чтобы поток не был ровным.")
            }

            Section {
                if running || downloaded > 0 {
                    ProgressView(value: progress)
                    HStack {
                        Text(Format.size(downloaded) + " из " + Format.size(totalBytes))
                        Spacer()
                        Text(clock(elapsed))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    .font(.footnote)
                    HStack {
                        Text("Средняя скорость")
                        Spacer()
                        Text(Format.rate(averageRate))
                            .foregroundColor(.secondary)
                    }
                    .font(.footnote)
                }
                if running {
                    Button(role: .destructive) {
                        stop()
                    } label: {
                        Label("Остановить", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        start()
                    } label: {
                        Label("Запустить тест", systemImage: "play.circle")
                    }
                    .disabled(!engine.running)
                }
                if !engine.running {
                    Text("Сначала подними ядро на вкладке «Серверы».")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Ход теста")
            } footer: {
                Text("Пока тест идёт, открой «Соединения»: «Сейчас» должно показывать около "
                     + Format.rate(averageRate) + ", а «С включения» расти ровно на объём теста.")
            }
        }
        .navigationTitle("Тест трафика")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stop() }
    }

    // MARK: - Запуск

    private func start() {
        guard !running else { return }
        downloaded = 0
        elapsed = 0
        note = "готовлю вход…"
        running = true
        task = Task { await run() }
    }

    private func stop() {
        task?.cancel()
        task = nil
        if running { note = "остановлено вручную" }
        running = false
    }

    @MainActor
    private func run() async {
        // Куда качать: активный сервер — основной вход, конкретный — его пробный вход.
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

        let session = makeSession(port: port)
        let rate = Double(totalBytes) / Double(max(minutes, 1) * 60)   // байт в секунду
        let started = Date()
        note = "идёт тест через " + serverTitle

        while !Task.isCancelled, downloaded < totalBytes {
            let left = totalBytes - downloaded
            // Куски разного размера: поток не выглядит «пулемётом» одинаковых запросов.
            let chunk = min(left, Int64.random(in: 700_000...1_400_000))
            let begin = Date()
            let got = await fetch(chunk: chunk, session: session)
            downloaded += got
            elapsed = Date().timeIntervalSince(started)
            if got == 0 { note = "сервер не ответил — тест остановлен"; break }

            // Держим средний темп: спим столько, сколько «перебрали» по скорости,
            // плюс случайная добавка до 25 %.
            let spent = Date().timeIntervalSince(begin)
            let should = Double(got) / rate
            var pause = should - spent
            if pause > 0 {
                pause *= Double.random(in: 0.85...1.25)
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        elapsed = Date().timeIntervalSince(started)
        if !Task.isCancelled, downloaded >= totalBytes {
            note = "готово: " + Format.size(downloaded) + " за " + clock(elapsed)
        }
        running = false
    }

    /// Один кусок через локальный вход ядра. Возвращает, сколько реально пришло.
    private func fetch(chunk: Int64, session: URLSession) async -> Int64 {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=" + String(chunk)) else {
            return 0
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, _) = try? await session.data(for: request) else { return 0 }
        return Int64(data.count)
    }

    /// Сессия, которая ходит не напрямую, а через локальный SOCKS ядра.
    private func makeSession(port: Int) -> URLSession {
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

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

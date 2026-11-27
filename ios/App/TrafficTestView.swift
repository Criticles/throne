import SwiftUI

/// Тест трафика: качаем заданный объём через выбранный сервер ровно за заданное время,
/// чтобы глазами проверить счётчики («сейчас / за окно / с включения»).
///
/// Работает и в LiveContainer: там нет расширения, но ядро живёт в процессе приложения
/// (`DevPlatform`) и слушает локальный SOCKS — тест идёт через него.
/// Сам прогон живёт в `TrafficTester.shared`, поэтому уход с экрана его не прерывает.
struct TrafficTestView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @ObservedObject private var tester = TrafficTester.shared

    @State private var volume = 10
    @State private var minutes = 1
    @State private var serverID: UUID?

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
                .disabled(tester.running)
            } header: {
                Text("Параметры")
            } footer: {
                Text("Трафик теста идёт через твой сервер и учитывается в его лимитах — "
                     + "как обычная загрузка. Куски и паузы рандомизированы, чтобы поток не был ровным.")
            }

            Section {
                if tester.running || tester.downloaded > 0 {
                    ProgressView(value: tester.progress)
                    HStack {
                        Text(Format.size(tester.downloaded) + " из " + Format.size(tester.total))
                        Spacer()
                        Text(TrafficTester.clock(tester.elapsed))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    .font(.footnote)
                    HStack {
                        Text("Средняя скорость")
                        Spacer()
                        Text(Format.rate(tester.averageRate))
                            .foregroundColor(.secondary)
                    }
                    .font(.footnote)
                }
                if tester.running {
                    Button(role: .destructive) {
                        tester.stop()
                    } label: {
                        Label("Остановить", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        tester.start(volumeMB: volume, minutes: minutes, serverID: serverID,
                                     profile: serverTitle, engine: engine, servers: servers)
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
                if !tester.note.isEmpty {
                    Text(tester.note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Ход теста")
            } footer: {
                Text("Уходить с экрана можно — тест продолжится. Счётчики смотри в «Соединениях».")
            }
        }
        .navigationTitle("Тест трафика")
        .navigationBarTitleDisplayMode(.inline)
    }
}

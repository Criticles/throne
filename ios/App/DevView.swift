import SwiftUI

/// Dev-режим: проверка реального трафика без Network Extension.
/// Подписка (текст или URL) → профили → старт локального SOCKS → проверка через него.
struct DevView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var engine = DevEngine()
    @StateObject private var logs = LogStore.shared

    @State private var subscriptionURL = ""
    @State private var probeResult = ""
    @State private var probing = false

    var body: some View {
        List {
            Section("Подписка или ссылка") {
                TextField("URL подписки или vless:// hy2:// mierus:// wg://", text: $subscriptionURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                HStack {
                    Button(store.loading ? "Загрузка…" : "Добавить") {
                        Task { await store.importAny(subscriptionURL) }
                    }
                    .disabled(store.loading)

                    Button("Из буфера") {
                        if let text = UIPasteboard.general.string, !text.isEmpty {
                            store.importFromText(text)
                        } else {
                            engine.report("буфер обмена пуст")
                        }
                    }

                    Spacer()

                    Button("Очистить") { store.removeAll() }
                        .foregroundColor(.red)
                }
                .font(.callout)
                // Без этого в List несколько кнопок в строке конфликтуют: нажатие уходит
                // в первую («Добавить»), а «Очистить» не срабатывает.
                .buttonStyle(.borderless)

                if !store.status.isEmpty {
                    Text(store.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Профили: \(store.profiles.count)") {
                if store.profiles.isEmpty {
                    Text("пусто — загрузите подписку или вставьте ссылки из буфера")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(store.profiles) { profile in
                    Button {
                        store.select(profile.id)
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: store.selectedID == profile.id
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundColor(store.selectedID == profile.id ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.callout)
                                HStack(spacing: 6) {
                                    Text(badge(for: profile))
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                    if let note = profile.note {
                                        Text("ограничено")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                                if let note = profile.note {
                                    Text(note).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Подключение") {
                HStack(spacing: 10) {
                    Button(engine.running ? "Перезапустить" : "Старт") { startSelected() }
                        .buttonStyle(.borderedProminent)
                    Button("Стоп") { engine.stop() }
                        .buttonStyle(.bordered)
                        .disabled(!engine.running)
                    Spacer()
                    Circle()
                        .fill(engine.running ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                }

                if let active = engine.activeName {
                    Text("активен: \(active)").font(.caption).foregroundColor(.secondary)
                }
                if let error = engine.lastError {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                if store.selected?.kind == .wireturn {
                    // Под TURN/SRTP панельные 1280 фрагментируются: хендшейки проходят,
                    // а TCP-трафик умирает. Даём крутить MTU и смотреть по логу.
                    HStack(spacing: 8) {
                        Text("MTU").font(.caption).foregroundColor(.secondary)
                        Button("−20") { engine.wireturnMTU = max(1000, engine.wireturnMTU - 20) }
                        Text("\(engine.wireturnMTU)").font(.system(.caption, design: .monospaced))
                        Button("+20") { engine.wireturnMTU = min(1420, engine.wireturnMTU + 20) }
                        Spacer()
                        Text("меньше — если трафик не идёт").font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                Text("Выход в интернет через \(engine.socksAddress)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(probing ? "Проверяю…" : "Проверить IP и страну") {
                    Task { await probe() }
                }
                .buttonStyle(.bordered)
                .disabled(!engine.running || probing || engine.bulkRunning)

                if !probeResult.isEmpty {
                    Text(probeResult)
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                }
            }

            Section("Проверка всех серверов") {
                Button(engine.bulkRunning ? "Проверяю…" : "Проверить все (\(store.profiles.count))") {
                    Task { await engine.checkAll(profiles: store.profiles) }
                }
                .buttonStyle(.bordered)
                .disabled(engine.bulkRunning || probing || store.profiles.isEmpty)

                ForEach(engine.bulk) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.caption)
                            Text(row.badge)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        }
                        if let result = row.result {
                            Text(result.summary)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(result.ok ? .green : .red)
                        } else if let note = row.note {
                            Text(note).font(.caption2).foregroundColor(.orange)
                        } else if !row.done {
                            Text("в очереди").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Общий журнал").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Копировать всё") {
                        UIPasteboard.general.string = [
                            logs.text,
                            "=== проверка трафика ===",
                            probeResult,
                            "=== активный профиль ===",
                            engine.activeName ?? "-",
                        ].joined(separator: "\n")
                    }
                    .font(.caption)
                    Button("Очистить") { engine.clearLog() }.font(.caption)
                }
                Text(logs.text.isEmpty ? "пусто" : logs.text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Dev")
    }

    private func startSelected() {
        guard let profile = store.selected else {
            engine.report("сначала выберите профиль")
            return
        }
        engine.start(profile: profile)
        if engine.running && !engine.isListening() {
            // Ядро сообщило «старт», но порт не слушается: чаще всего остался прошлый
            // экземпляр или в конфиге ошибка — тогда проверка трафика врёт про сервер.
            probeResult = "ядро не слушает 127.0.0.1:\(ConfigBuilder.listenPort) — смотрите лог ядра"
            return
        }
        if engine.running {
            probeResult = "проверяю…"
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await probe()
            }
        }
    }

    /// Проверка выхода: с какого IP и из какой страны нас видит интернет.
    private func probe() async {
        probing = true
        defer { probing = false }
        let result = await Probe.viaProxy(port: ConfigBuilder.listenPort)
        probeResult = result.summary
        logs.append("проверка выхода: \(result.summary)")
    }

    /// «sing-box JSON» ничего не говорит о протоколе — показываем протокол, а формат уточняем.
    private func badge(for profile: Profile) -> String {
        profile.badge ?? profile.kind.title
    }
}

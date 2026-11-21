import SwiftUI

/// Dev-режим: проверка реального трафика без Network Extension.
/// Подписка (текст или URL) → профили → старт локального SOCKS → проверка через него.
struct DevView: View {
    @StateObject private var store = ProfileStore()
    @StateObject private var engine = DevEngine()

    @State private var subscriptionURL = ""
    @State private var probeURL = "https://api.ipify.org?format=json"
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

                Text("Проверка через \(engine.socksAddress)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("URL", text: $probeURL)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Button(probing ? "Проверяю…" : "Проверить") {
                    Task { await probe() }
                }
                .buttonStyle(.bordered)
                .disabled(!engine.running || probing)

                if !probeResult.isEmpty {
                    Text(probeResult)
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                }
            }

            Section {
                HStack {
                    Text("Лог ядра").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Очистить") { engine.clearLog() }.font(.caption)
                }
                Text(engine.log.isEmpty ? "пусто" : engine.log)
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

    private func probe() async {
        let raw = probeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else {
            probeResult = "некорректный URL: «\(raw)»"
            return
        }
        probing = true
        defer { probing = false }

        // mixed-инбаунд понимает и HTTP CONNECT, и SOCKS5. CFNetwork для https через SOCKS
        // часто отдаёт kCFErrorDomainCFNetwork 310 («не удалось соединение с прокси»),
        // поэтому сначала идём через HTTP-прокси, а SOCKS оставляем вторым заходом.
        let viaHTTP = await request(url, proxy: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(ConfigBuilder.listenPort),
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(ConfigBuilder.listenPort),
        ])
        if viaHTTP.hasPrefix("HTTP") {
            probeResult = viaHTTP
            return
        }

        let viaSOCKS = await request(url, proxy: [
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": Int(ConfigBuilder.listenPort),
        ])
        probeResult = viaSOCKS.hasPrefix("HTTP")
            ? viaSOCKS
            : "HTTP-прокси: \(viaHTTP)\nSOCKS: \(viaSOCKS)"
    }

    private func request(_ url: URL, proxy: [AnyHashable: Any]) async -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.connectionProxyDictionary = proxy
        let session = URLSession(configuration: configuration)
        let started = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "<бинарные данные>"
            return "HTTP \(code) за \(millis) мс\n\(body)"
        } catch {
            let ns = error as NSError
            var detail = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail += " ← \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
            }
            return "ошибка: \(detail)"
        }
    }

    /// «sing-box JSON» ничего не говорит о протоколе — показываем протокол, а формат уточняем.
    private func badge(for profile: Profile) -> String {
        guard profile.kind == .custom else { return profile.kind.title }
        if let separator = profile.name.range(of: " · ") {
            return String(profile.name[..<separator.lowerBound]) + " · JSON"
        }
        return "JSON панели"
    }
}

import SwiftUI

/// Dev-режим: проверка реального трафика без Network Extension.
/// Вставляете share-ссылку, жмёте «Старт» — sing-box поднимает локальный SOCKS,
/// а кнопка «Проверить» делает HTTP-запрос через него.
struct DevView: View {
    @StateObject private var engine = DevEngine()
    @AppStorage("dev.lastLink") private var linkText = ""
    @State private var probeURL = "https://api.ipify.org?format=json"
    @State private var probeResult = ""
    @State private var probing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Share-ссылка VLESS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $linkText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

                HStack(spacing: 10) {
                    Button(engine.running ? "Перезапустить" : "Старт") {
                        startEngine()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Стоп") { engine.stop() }
                        .buttonStyle(.bordered)
                        .disabled(!engine.running)

                    Spacer()

                    Circle()
                        .fill(engine.running ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                }

                if let error = engine.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Проверка трафика через \(engine.socksAddress)")
                    .font(.subheadline)
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                }

                HStack {
                    Text("Лог ядра")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Очистить") { engine.clearLog() }
                        .font(.caption)
                }

                Text(engine.log.isEmpty ? "пусто" : engine.log)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("Dev")
    }

    private func startEngine() {
        do {
            let link = try VLESSLink.parse(linkText)
            engine.start(link: link)
        } catch {
            probeResult = ""
            engine.report("разбор ссылки: \((error as NSError).localizedDescription)")
        }
    }

    private func probe() async {
        guard let url = URL(string: probeURL) else {
            probeResult = "некорректный URL"
            return
        }
        probing = true
        defer { probing = false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        // На iOS константы kCFNetworkProxiesSOCKS* не экспортируются (они macOS-only),
        // но connectionProxyDictionary их принимает строковыми ключами.
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": Int(DevConfig.listenPort),
        ]
        let session = URLSession(configuration: configuration)
        let started = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "<бинарные данные>"
            probeResult = "HTTP \(code) за \(millis) мс\n\(body)"
        } catch {
            let ns = error as NSError
            probeResult = "ошибка: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
    }
}

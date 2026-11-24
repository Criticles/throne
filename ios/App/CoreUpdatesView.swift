import SwiftUI

/// Проверка обновлений ядер: sing-box, Xray и Turnable (WireTurn).
/// Ядра вшиты в сборку, поэтому «обновить» здесь — узнать о новой версии и открыть релиз.
struct CoreUpdatesView: View {
    struct Core: Identifiable {
        let id: String
        let name: String
        let repo: String
        let current: String
    }

    @State private var latest: [String: String] = [:]
    @State private var status: [String: String] = [:]
    @State private var checking = false

    private let cores: [Core] = [
        Core(id: "singbox", name: "sing-box", repo: "throneproj/sing-box",
             current: CoreInfo.singboxBranch),
        Core(id: "xray", name: "Xray", repo: "throneproj/Xray-core",
             current: "форк throneproj"),
        Core(id: "turnable", name: "Turnable (WireTurn)", repo: "TheAirBlow/Turnable",
             current: CoreInfo.turnableVersion),
    ]

    var body: some View {
        List {
            Section {
                ForEach(cores) { core in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(core.name).font(.subheadline.weight(.medium))
                            Spacer()
                            if checking {
                                ProgressView().scaleEffect(0.6)
                            }
                        }
                        Text(core.repo).font(.caption2).foregroundColor(.secondary)
                        Text("сейчас: " + core.current)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let text = status[core.id] {
                            Text(text)
                                .font(.caption2)
                                .foregroundColor(text.contains("новее") ? .orange : .secondary)
                        }
                        if let tag = latest[core.id],
                           let url = URL(string: "https://github.com/" + core.repo + "/releases/tag/" + tag) {
                            Link("Открыть " + tag, destination: url)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    Task { await checkAll() }
                } label: {
                    Label(checking ? "Проверяю…" : "Проверить все", systemImage: "arrow.clockwise")
                }
                .disabled(checking)
            } footer: {
                Text("Ядра собираются вместе с приложением. Здесь видно, есть ли в репозитории более новая версия и ссылка на релиз.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Обновления ядер")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func checkAll() async {
        checking = true
        defer { checking = false }
        for core in cores {
            await check(core)
        }
    }

    private func check(_ core: Core) async {
        guard let url = URL(string: "https://api.github.com/repos/" + core.repo + "/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any],
              let tag = object["tag_name"] as? String
        else {
            status[core.id] = "не удалось проверить"
            return
        }
        latest[core.id] = tag
        status[core.id] = "последний релиз: " + tag
    }
}

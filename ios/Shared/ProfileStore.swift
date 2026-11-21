import Foundation

/// Профили в dev-режиме: импорт из текста/по URL, выбор активного, сохранение между запусками.
///
/// Хранятся в UserDefaults приложения. Внутри — ключи и пароли из подписки,
/// поэтому по умолчанию это только локальное хранилище на устройстве.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var status: String = ""
    @Published private(set) var loading = false

    private let profilesKey = "dev.profiles"
    private let selectedKey = "dev.selectedProfile"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    var selected: Profile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
    }

    func select(_ id: UUID) {
        selectedID = id
        defaults.set(id.uuidString, forKey: selectedKey)
    }

    func importFromText(_ text: String) {
        let parsed = ProfileParser.parse(text: text)
        guard !parsed.isEmpty else {
            status = "в тексте не нашлось поддерживаемых профилей"
            return
        }
        merge(parsed)
        status = "добавлено профилей: \(parsed.count)"
    }

    func importFromURL(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else {
            status = "нужен http(s)-адрес подписки"
            return
        }
        loading = true
        defer { loading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Многие панели отдают разное в зависимости от User-Agent; этот — как у Throne.
        request.setValue("Throne/0.1 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                status = "подписка вернула HTTP \(code)"
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                status = "ответ подписки не в UTF-8"
                return
            }
            importFromText(text)
        } catch {
            let ns = error as NSError
            status = "ошибка загрузки: \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
    }

    func removeAll() {
        profiles = []
        selectedID = nil
        defaults.removeObject(forKey: profilesKey)
        defaults.removeObject(forKey: selectedKey)
        status = "список очищен"
    }

    // MARK: - Внутреннее

    private func merge(_ incoming: [Profile]) {
        var seen = Set(profiles.map { "\($0.kind.rawValue)|\($0.name)|\($0.payload)" })
        for profile in incoming {
            let key = "\(profile.kind.rawValue)|\(profile.name)|\(profile.payload)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            profiles.append(profile)
        }
        if selectedID == nil {
            selectedID = profiles.first?.id
            defaults.set(selectedID?.uuidString, forKey: selectedKey)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    private func load() {
        if let data = defaults.data(forKey: profilesKey),
           let stored = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = stored
        }
        if let raw = defaults.string(forKey: selectedKey), let id = UUID(uuidString: raw) {
            selectedID = id
        }
    }
}

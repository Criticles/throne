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

    @discardableResult
    func importFromText(_ text: String) -> Int {
        let parsed = ProfileParser.parse(text: text)
        guard !parsed.isEmpty else {
            status = "в тексте не нашлось поддерживаемых профилей"
            return 0
        }
        let added = merge(parsed)
        status = "добавлено профилей: \(added) (всего \(profiles.count))"
        return added
    }

    /// Одно поле ввода на всё: http(s) — подписка, иначе — одна или несколько share-ссылок.
    func importAny(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            await importFromURL(trimmed)
        } else {
            importFromText(trimmed)
        }
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

        var added = 0
        var problems: [String] = []

        do {
            let list = try await fetch(url, userAgent: "v2rayNG/1.8.5")
            if list.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                problems.append("вместо подписки пришёл HTML")
            } else {
                added += importParsed(ProfileParser.parse(text: list))
            }
        } catch {
            problems.append("список: \(Self.describe(error))")
        }

        do {
            let configText = try await fetch(url, userAgent: "Throne/0.1 (iOS)")
            if configText.contains("\"outbounds\"") {
                added += importParsed(ProfileParser.parse(text: configText))
            }
        } catch {
            problems.append("конфиг: \(Self.describe(error))")
        }

        // Панель отдаёт AmneziaWG только клиенту YPtun (проверено: 3 ссылки вместо 2).
        do {
            let yptunList = try await fetch(url, userAgent: "YPtun/3.7.0")
            if !yptunList.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                added += importParsed(ProfileParser.parse(text: yptunList))
            }
        } catch {
            problems.append("AWG: \(Self.describe(error))")
        }

        if added > 0 {
            status = "добавлено профилей: \(added) (всего \(profiles.count))"
        } else {
            status = problems.isEmpty
                ? "в подписке не нашлось поддерживаемых профилей"
                : problems.joined(separator: " · ")
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

    private func fetch(_ url: URL, userAgent: String) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw NSError(domain: "orbita.subscription", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "orbita.subscription", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "ответ не в UTF-8"])
        }
        return text
    }

    @discardableResult
    private func importParsed(_ parsed: [Profile]) -> Int {
        guard !parsed.isEmpty else { return 0 }
        return merge(parsed)
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    /// `?format=turnable` и `?format=wireturn` отдают одни и те же серверы в двух обёртках —
    /// поэтому Turnable-профили сравниваем по имени, иначе список удваивается.
    private func dedupeKey(_ profile: Profile) -> String {
        switch profile.kind {
        case .turnable, .wireturn:
            return "turnable|\(profile.name)"
        default:
            return "\(profile.kind.rawValue)|\(profile.name)|\(profile.payload)"
        }
    }

    @discardableResult
    private func merge(_ incoming: [Profile]) -> Int {
        var seen = Set(profiles.map { dedupeKey($0) })
        var added = 0
        for profile in incoming {
            let key = dedupeKey(profile)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            profiles.append(profile)
            added += 1
        }
        if selectedID == nil {
            selectedID = profiles.first?.id
            defaults.set(selectedID?.uuidString, forKey: selectedKey)
        }
        if added > 0 {
            save()
        }
        return added
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

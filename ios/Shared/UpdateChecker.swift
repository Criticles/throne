import Foundation
import SwiftUI

/// Проверка обновлений по релизам GitHub: сборку мы выкладываем вручную, поэтому
/// источник версии — тег последнего релиза, а не App Store.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release {
        let version: String
        let url: URL
        let notes: String?
    }

    @Published private(set) var latest: String?
    @Published private(set) var available: Release?
    @Published private(set) var status = ""
    @Published private(set) var checking = false

    private let repo = "Criticles/throne"

    /// Установленная версия: «0.1.0 (42)».
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return short + " (" + build + ")"
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        available = nil

        guard let url = URL(string: "https://api.github.com/repos/" + repo + "/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Throne-iOS", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                // 404 — релизов пока нет. Это не ошибка, просто нечего предлагать.
                latest = nil
                status = code == 404 ? "релизов на GitHub ещё нет" : "GitHub ответил " + String(code)
                return
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any]
            else {
                status = "не разобрать ответ GitHub"
                return
            }
            let tag = (object["tag_name"] as? String) ?? (object["name"] as? String) ?? ""
            latest = tag
            let link = (object["html_url"] as? String).flatMap { URL(string: $0) }
                ?? URL(string: "https://github.com/" + repo + "/releases")!

            if Self.isNewer(tag, than: Self.currentVersion) {
                available = Release(version: tag, url: link, notes: object["body"] as? String)
                status = "доступна версия " + tag
            } else {
                status = "у вас последняя версия (" + Self.currentVersion + ")"
            }
        } catch {
            status = "проверка не удалась: " + error.localizedDescription
        }
    }

    /// «v0.2.0» новее «0.1.0 (42)»: сравниваем числа, префикс v и скобки игнорируем.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let left = numbers(tag)
        let right = numbers(current)
        guard !left.isEmpty else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

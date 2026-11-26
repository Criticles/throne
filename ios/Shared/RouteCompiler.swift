import Foundation

/// Компилятор профиля маршрутизации в `route.rules` ядра.
///
/// Модель повторяет настольный Throne: папка — это одно правило, порядок папок = порядок
/// применения сверху вниз, атрибуты внутри папки складываются по И (в sing-box поля одного
/// правила объединяются именно так), значения одного атрибута — по ИЛИ.
enum RouteCompiler {
    struct Context {
        /// Имя сервера → тег outbound/endpoint в собранном конфиге.
        let tagsByName: [String: String]
        /// Тег выбранного сервера: имя «proxy» означает именно его.
        let selectedTag: String?
    }

    enum Target {
        case outbound(String)
        case reject
    }

    /// Поля-действия не считаются условием: правило только с ними поймало бы весь трафик.
    private static let actionAttributes: Set<String> = [
        "outbound", "method", "no_drop", "tls_spoof", "tls_spoof_method",
        "override_address", "override_port",
    ]

    /// Чего ядро в правилах не понимает или что нельзя собрать без дополнительных данных.
    /// `rule_set` требует определённых в конфиге наборов — их пока не поставляем;
    /// `strategy` в правилах не существует; `override_destination` живёт у `action: sniff`.
    private static let skipped: Set<String> = ["strategy", "rule_set", "override_destination"]

    /// Числа, булевы и одиночные строки описывает `RouteAttribute.jsonValue` — здесь
    /// только то, что в правила ядра не пойдёт.

    /// Правила профиля по порядку папок. Пустые папки и папки только на `rule_set`
    /// пропускаются — иначе правило без условий перехватило бы всё.
    static func rules(plan: RoutePlan?, context: Context) -> [[String: Any]] {
        guard let plan else { return [] }
        return plan.rules.compactMap { rule(for: $0, context: context) }
    }

    /// `final` профиля: имя сервера, proxy/direct или reject (reject как final ядро не умеет —
    /// тогда возвращаем nil, и вызывающий оставляет direct).
    static func finalTag(plan: RoutePlan?, context: Context) -> String? {
        guard let plan else { return nil }
        switch destination(plan.finalTarget, context: context) {
        case .outbound(let tag): return tag
        default: return nil
        }
    }

    static func destination(_ name: String, context: Context) -> Target? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key.lowercased() {
        case "reject": return .reject
        case "direct": return .outbound("direct")
        case "proxy", "": return context.selectedTag.map(Target.outbound)
        default:
            if let tag = context.tagsByName[key] { return .outbound(tag) }
            return context.selectedTag.map(Target.outbound)
        }
    }

    private static let rejectMethods: Set<String> = ["default", "drop", "reply"]

    private static func rule(for folder: RoutePlanRule, context: Context) -> [String: Any]? {
        var body: [String: Any] = [:]
        for attr in folder.attrs where !RouteAttribute.unavailable.contains(attr.attr) {
            guard let value = payload(attr.attr, attr.values) else { continue }
            body[attr.attr] = value
        }
        let conditions = body.keys.filter { !actionAttributes.contains($0) }
        guard !conditions.isEmpty else { return nil }

        switch destination(folder.action == "reject" ? "reject" : folder.outbound, context: context) {
        case .reject:
            // `method` и `no_drop` существуют только у reject; `no_drop` вместе с
            // `method: drop` ядро отвергает («no_drop is not available in current context»).
            body["action"] = "reject"
            if let method = body["method"] as? String, !rejectMethods.contains(method) {
                body.removeValue(forKey: "method")
            }
            if (body["method"] as? String) == "drop" {
                body.removeValue(forKey: "no_drop")
            }
        case .outbound(let tag):
            // У действия route этих полей нет вовсе: `unknown field "method"`.
            body.removeValue(forKey: "method")
            body.removeValue(forKey: "no_drop")
            body["outbound"] = tag
        case .none:
            body.removeValue(forKey: "method")
            body.removeValue(forKey: "no_drop")
            body["outbound"] = context.selectedTag ?? "direct"
        }
        return body
    }

    /// Значение в том типе, который ждёт ядро. nil — атрибут не компилируется.
    /// Сами типы живут в `RouteAttribute.jsonValue`: экспорт и конфиг должны совпадать.
    private static func payload(_ attr: String, _ values: [String]) -> Any? {
        guard !skipped.contains(attr) else { return nil }
        return RouteAttribute.jsonValue(attr, values)
    }
}

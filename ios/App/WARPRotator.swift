import Foundation

/// Автоподбор эндпоинта WARP: если текущий перестал подниматься, берём следующий
/// из проверенного списка, пока туннель не ответит.
@MainActor
final class WARPRotator {
    static let shared = WARPRotator()

    private var busy = false

    /// Один шаг: переписать профиль на следующий эндпоинт, поднять ядро, проверить.
    /// Возвращает обновлённый профиль, если он рабочий, иначе nil.
    func rotate(profile: Profile,
                store: ProfileStore,
                engine: DevEngine,
                plan: RoutePlan?,
                quickPlan: RoutePlan?,
                ruleSetPaths: [String: String]) async -> Profile? {
        guard !busy, let account = WARPCreator.account(from: profile.payload) else { return nil }
        busy = true
        defer { busy = false }

        let start = WARPCreator.endpointIndex(in: profile.payload)
        let next = (start + 1) % WARPCreator.endpoints.count
        let endpoint = WARPCreator.endpoints[next]
        let payload = WARPCreator.payload(account: account, endpoint: endpoint)
        store.updateWARP(profile: profile, payload: payload, endpoint: endpoint)

        guard let updated = store.profiles.first(where: { $0.id == profile.id }) else { return nil }
        engine.start(profile: updated, pool: store.profiles, plan: plan,
                     quickPlan: quickPlan, ruleSetPaths: ruleSetPaths)
        guard engine.running, !engine.transportOnly else { return nil }
        await engine.probeActive(profile: updated)
        let ok = engine.bulk.first(where: { $0.id == updated.id })?.result?.ok ?? false
        return ok ? updated : nil
    }

    /// Перебирает до `attempts` эндпоинтов, начиная со следующего за текущим.
    func findWorking(profile: Profile,
                     store: ProfileStore,
                     engine: DevEngine,
                     plan: RoutePlan?,
                     quickPlan: RoutePlan?,
                     ruleSetPaths: [String: String],
                     attempts: Int = 4) async -> Profile? {
        var current = profile
        for _ in 0..<attempts {
            if let working = await rotate(profile: current, store: store, engine: engine,
                                          plan: plan, quickPlan: quickPlan,
                                          ruleSetPaths: ruleSetPaths) {
                return working
            }
            current = store.profiles.first(where: { $0.id == profile.id }) ?? current
        }
        return nil
    }
}

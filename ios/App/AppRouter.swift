import SwiftUI

/// Что добавить в маршрутизацию из «Соединений»: атрибут и значение уже подставлены.
struct RouteInsertPrefill: Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var attr = "domain"
    var value = ""
}

/// Переключение вкладок и переход из «Соединений» в маршрутизацию.
@MainActor
final class AppRouter: ObservableObject {
    /// 0 — Серверы, 1 — Маршрут, 2 — Соединения, 3 — Настройки.
    @Published var tab = 0
    /// Что добавить в правило: профиль маршрута сам предложит папку.
    @Published var pendingInsert: RouteInsertPrefill?

    /// Никаких листов: уходим на вкладку «Маршрут», там профиль покажет заявку.
    func openRouting(with prefill: RouteInsertPrefill) {
        pendingInsert = prefill
        tab = 1
    }
}

/// Добавление значения в выбранную папку выбранного профиля маршрутизации.
///
/// Порядок как у настольного клиента: профиль → папка с атрибутами → значение.
/// Если папок в профиле ещё нет, её можно создать прямо здесь.

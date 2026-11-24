import Foundation
import UserNotifications

/// Локальные уведомления о конце подписки: iOS не умеет фоновые задачи,
/// но запланированное уведомление отдаёт система сама, даже если приложение закрыто.
enum SubscriptionAlerts {
    static let identifierPrefix = "sub-expiry-"

    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Ставит напоминание за `daysBefore` дней до окончания. Повторный вызов заменяет прошлое.
    static func schedule(_ subscription: Subscription, daysBefore: Int = 3) async {
        let center = UNUserNotificationCenter.current()
        let identifier = identifierPrefix + subscription.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard let expire = subscription.expire else { return }
        let fireDate = Calendar.current.date(byAdding: .day, value: -max(daysBefore, 0), to: expire) ?? expire
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Подписка заканчивается"
        content.body = subscription.name + ": осталось " + String(daysBefore) + " дн."
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancel(_ subscription: Subscription) {
        let identifier = identifierPrefix + subscription.id.uuidString
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Сколько дней осталось до конца подписки (nil — если срок не известен).
    static func daysLeft(_ subscription: Subscription) -> Int? {
        guard let expire = subscription.expire else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expire).day
    }
}

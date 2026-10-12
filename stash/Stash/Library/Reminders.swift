import Foundation
import UserNotifications

/// Notifications for item reminders. A reminder is stored on the item
/// (`remindAt`) and syncs; each device schedules its own notification from
/// it, and they're all rebuilt from the library after launch and after
/// changes arrive from iCloud, as the search index is.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()

    /// Called with the item's id when a notification is chosen.
    var onOpen: (UUID) -> Void = { _ in }
    private var center: UNUserNotificationCenter { .current() }
    private static let prefix = "stash-reminder-"

    /// Must happen before the app finishes launching, so choosing a
    /// notification that launched it is heard.
    func start() {
        center.delegate = self
    }

    /// Asks once; afterwards the system remembers the answer.
    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func schedule(_ item: Item) {
        let id = Self.prefix + item.uuid.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let date = item.remindAt, date > .now, !item.isTrashed else { return }
        center.add(Self.request(id: id, item: item, date: date))
    }

    func cancel(_ items: [Item]) {
        center.removePendingNotificationRequests(withIdentifiers: items.map { Self.prefix + $0.uuid.uuidString })
    }

    func replaceAll(with items: [Item]) {
        let requests = items.compactMap { item -> UNNotificationRequest? in
            guard let date = item.remindAt, date > .now, !item.isTrashed else { return nil }
            return Self.request(id: Self.prefix + item.uuid.uuidString, item: item, date: date)
        }
        let center = self.center
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            for request in requests { center.add(request) }
        }
    }

    private static func request(id: String, item: Item, date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.displayTitle
        content.body = item.isLocked || item.listSubtitle.isEmpty ? "Reminder from Stash" : String(item.listSubtitle.prefix(180))
        content.sound = .default
        content.userInfo = ["item": item.uuid.uuidString]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while Stash is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["item"] as? String).flatMap(UUID.init(uuidString:)) else {
            return
        }
        await MainActor.run { onOpen(id) }
    }
}

import Foundation
import UIKit
import UserNotifications

enum ReminderScheduler {
    static let categoryID      = "DOSE_CATEGORY"
    static let tookItActionID  = "TOOK_IT"
    static let snoozeActionID  = "SNOOZE_10"

    private static let askedKey = "dosely.permissionAsked"

    // MARK: - Categories & actions

    static func registerCategories() {
        let took = UNNotificationAction(
            identifier: tookItActionID,
            title: L("notifications.action.tookit"),
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: snoozeActionID,
            title: L("notifications.action.snooze"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [took, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Permission

    static func currentStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
    }

    @discardableResult
    static func requestPermissionIfNeeded() async -> Bool {
        let status = await currentStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            UserDefaults.standard.set(true, forKey: askedKey)
            do {
                return try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    static var hasAskedBefore: Bool {
        UserDefaults.standard.bool(forKey: askedKey)
    }

    // MARK: - Scheduling

    static func scheduleReminders(for medication: Medication) {
        guard let medID = medication.id,
              let schedules = medication.schedules as? Set<DoseSchedule> else { return }
        let foodText = foodRuleDisplayText(medication.foodRule)
        let name = medication.name ?? ""
        let dose = medication.dose ?? ""

        for schedule in schedules {
            guard
                let schedID = schedule.id,
                let timeOfDay = schedule.timeOfDay,
                let (hour, minute) = parseHHmm(timeOfDay)
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = L("notifications.title")
            content.body = L("notifications.body", name as NSString, dose as NSString, foodText as NSString)
            content.sound = .default
            content.categoryIdentifier = categoryID
            var userInfo: [AnyHashable: Any] = [
                "medID": medID.uuidString,
                "scheduleID": schedID.uuidString,
                "scheduledHour": hour,
                "scheduledMinute": minute
            ]
            if let personID = medication.personID?.uuidString {
                userInfo["personID"] = personID
            }
            content.userInfo = userInfo

            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

            let identifier = "dose-\(medID.uuidString)-\(schedID.uuidString)"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().add(request)
        }
    }

    static func removeReminders(for medicationID: UUID) {
        let prefix = "dose-\(medicationID.uuidString)-"
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    static func scheduleSnooze(from response: UNNotificationResponse) {
        let original = response.notification.request
        let content = UNMutableNotificationContent()
        content.title = original.content.title
        content.body = original.content.body
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = original.content.userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(original.identifier)-snooze-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    static func scheduleTestNotification(after seconds: TimeInterval = 30) {
        let content = UNMutableNotificationContent()
        content.title = "Dosely test"
        content.body = "Test notification fired after \(Int(seconds))s."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: "debug-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NOTIF-DEBUG] add(request) error: \(error.localizedDescription)")
            }
        }
    }

    static func dumpPendingRequests() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            print("[NOTIF-DEBUG] pending notifications: \(requests.count)")
            for r in requests {
                print("[NOTIF-DEBUG]   id=\(r.identifier) fires=\(fireDateString(for: r.trigger))")
            }
        }
    }

    private static let debugISOFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func fireDateString(for trigger: UNNotificationTrigger?) -> String {
        if let cal = trigger as? UNCalendarNotificationTrigger, let d = cal.nextTriggerDate() {
            return debugISOFormatter.string(from: d)
        }
        if let ti = trigger as? UNTimeIntervalNotificationTrigger, let d = ti.nextTriggerDate() {
            return debugISOFormatter.string(from: d)
        }
        return "unknown"
    }
    #endif

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Helpers

    static func foodRuleDisplayText(_ rule: String?) -> String {
        switch rule {
        case "with":    return L("food.with")
        case "without": return L("food.without")
        default:        return L("food.either")
        }
    }

    private static func parseHHmm(_ string: String) -> (Int, Int)? {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (h, m)
    }

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

import UIKit
import UserNotifications

final class NotificationsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ReminderScheduler.registerCategories()
        return true
    }

    // Show banners even when the app is foregrounded, and speak the body
    // through `VoiceReadoutHelper` for the language the user picked. The
    // helper silently no-ops if no voice is installed for that language.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let body = notification.request.content.body
        VoiceReadoutHelper.speak(body)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case ReminderScheduler.tookItActionID:
            guard let medIDString = info["medID"] as? String,
                  let medID = UUID(uuidString: medIDString) else {
                print("[NOTIF-DEBUG] TOOK_IT: missing or invalid medID in userInfo")
                completionHandler(); return
            }
            let scheduledToday = Self.scheduledDate(from: info)
            let actualTime = Date()
            #if DEBUG
            print("[NOTIF-DEBUG] TOOK_IT handled: medID=\(medIDString) at \(ISO8601DateFormatter().string(from: actualTime))")
            #endif
            Task {
                let repo = MedicationRepository()
                _ = await repo.logDose(
                    medicationID: medID,
                    scheduledTime: scheduledToday,
                    actualTime: actualTime,
                    status: "taken"
                )
                await MainActor.run { completionHandler() }
            }

        case ReminderScheduler.snoozeActionID:
            ReminderScheduler.scheduleSnooze(from: response)
            completionHandler()

        default:
            // Default tap (open app). Nothing to log here; the app will surface the dose.
            completionHandler()
        }
    }

    private static func scheduledDate(from info: [AnyHashable: Any]) -> Date {
        let hour = info["scheduledHour"] as? Int ?? 0
        let minute = info["scheduledMinute"] as? Int ?? 0
        return Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()
        ) ?? Date()
    }
}

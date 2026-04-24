import SwiftUI

@main
struct DoselyApp: App {
    @UIApplicationDelegateAdaptor(NotificationsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            TodayView()
        }
    }
}

import SwiftUI
import UserNotifications

struct DebugToolbarModifier: ViewModifier {
    #if DEBUG
    @State private var showPermissionAlert = false
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Button(action: { Task { await handleTestTap() } }) {
                        Label("Test notification (30s)", systemImage: "bell.badge")
                            .dsCaption()
                            .foregroundColor(.dsPrimary)
                            .padding(.horizontal, DSSpacing.sm)
                            .frame(minHeight: 32)
                            .background(Color.dsSurface)
                            .cornerRadius(DSSpacing.rSm)
                            .overlay(
                                RoundedRectangle(cornerRadius: DSSpacing.rSm)
                                    .stroke(Color.dsPrimary, lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("DEBUG: schedule test notification in 30 seconds")
                    .padding(.trailing, DSSpacing.md)
                    .padding(.top, DSSpacing.xs)
                }
            }
            .task {
                // Auto-fire for shell-driven verification (e.g. `xcrun simctl launch ... -DoselyAutoTest`).
                if ProcessInfo.processInfo.arguments.contains("-DoselyAutoTest") {
                    await handleTestTap()
                }
            }
            .alert("Notifications are off", isPresented: $showPermissionAlert) {
                Button("Open Settings") { ReminderScheduler.openSystemSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tap Open Settings to enable them.")
            }
        #else
        content
        #endif
    }

    #if DEBUG
    @MainActor
    private func handleTestTap() async {
        let status = await ReminderScheduler.currentStatus()
        print("[NOTIF-DEBUG] tap: current auth status = \(ReminderScheduler.describe(status))")

        switch status {
        case .notDetermined:
            let granted = await ReminderScheduler.requestPermissionIfNeeded()
            let post = await ReminderScheduler.currentStatus()
            print("[NOTIF-DEBUG] after request: granted=\(granted), status=\(ReminderScheduler.describe(post))")
            if granted {
                scheduleAndDump()
            }
        case .denied:
            print("[NOTIF-DEBUG] denied — showing settings alert, not scheduling")
            showPermissionAlert = true
        case .authorized, .provisional, .ephemeral:
            scheduleAndDump()
        @unknown default:
            print("[NOTIF-DEBUG] unknown authorization status, not scheduling")
        }
    }

    private func scheduleAndDump() {
        ReminderScheduler.scheduleTestNotification(after: 30)
        print("[NOTIF-DEBUG] scheduled test notification for +30s")
        ReminderScheduler.dumpPendingRequests()
    }
    #endif
}

extension View {
    func debugToolbar() -> some View {
        modifier(DebugToolbarModifier())
    }
}

import SwiftUI
import UserNotifications

struct DebugToolbarModifier: ViewModifier {
    #if DEBUG
    @EnvironmentObject var authService: AuthService
    @State private var showPermissionAlert = false
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .safeAreaInset(edge: .top) {
                VStack(spacing: DSSpacing.xs) {
                    HStack(spacing: DSSpacing.xs) {
                        Spacer()
                        pill(title: "Test notification (30s)",
                             a11y: "DEBUG: schedule test notification in 30 seconds") {
                            Task { await handleTestTap() }
                        }
                        pill(title: "Schedule real dose (2 min)",
                             a11y: "Schedule real dose verification in 2 minutes") {
                            Task { await handleScheduleVerifyRx() }
                        }
                    }
                    HStack(spacing: DSSpacing.xs) {
                        Spacer()
                        pill(title: "Clear drug cache",
                             a11y: "DEBUG: clear drug info cache") {
                            Task {
                                await DrugInfoCache.shared.clear()
                                print("[DRUG-DEBUG] cleared")
                            }
                        }
                    }
                }
                .padding(.trailing, DSSpacing.md)
                .padding(.top, DSSpacing.xs)
            }
            .task {
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
    private func pill(title: String, a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "bell.badge")
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
        .accessibilityLabel(a11y)
    }

    @MainActor
    private func performWithPermission(_ action: @MainActor @escaping () async -> Void) async {
        let status = await ReminderScheduler.currentStatus()
        print("[NOTIF-DEBUG] tap: current auth status = \(ReminderScheduler.describe(status))")

        switch status {
        case .notDetermined:
            let granted = await ReminderScheduler.requestPermissionIfNeeded()
            let post = await ReminderScheduler.currentStatus()
            print("[NOTIF-DEBUG] after request: granted=\(granted), status=\(ReminderScheduler.describe(post))")
            if granted { await action() }
        case .denied:
            print("[NOTIF-DEBUG] denied — showing settings alert, not scheduling")
            showPermissionAlert = true
        case .authorized, .provisional, .ephemeral:
            await action()
        @unknown default:
            print("[NOTIF-DEBUG] unknown authorization status, not scheduling")
        }
    }

    @MainActor
    private func handleTestTap() async {
        await performWithPermission {
            ReminderScheduler.scheduleTestNotification(after: 30)
            print("[NOTIF-DEBUG] scheduled test notification for +30s")
            ReminderScheduler.dumpPendingRequests()
        }
    }

    @MainActor
    private func handleScheduleVerifyRx() async {
        await performWithPermission {
            await scheduleVerifyRx()
        }
    }

    @MainActor
    private func scheduleVerifyRx() async {
        guard let actorID = authService.currentPerson?.id else {
            print("[NOTIF-DEBUG] scheduleVerifyRx: no currentPerson — sign in first")
            return
        }
        let repository = MedicationRepository()

        let calendar = Calendar.current
        let future = Date().addingTimeInterval(2 * 60)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: future)
        let fireDate = calendar.date(from: comps) ?? future
        let hhmm = Self.hhmmFormatter.string(from: fireDate)

        let med: Medication
        do {
            med = try await repository.saveMedication(
                personID: actorID,
                actorPersonID: actorID,
                name: "Verify Rx",
                dose: "10mg",
                pillsPerDose: 1,
                foodRule: "either",
                notes: "Debug verification med",
                currentSupply: 30,
                pillPhotoData: nil,
                schedules: [ScheduleInput(timeOfDay: hhmm, daysOfWeek: 127)]
            )
        } catch {
            print("[NOTIF-DEBUG] scheduleVerifyRx failed: \(error)")
            return
        }
        ReminderScheduler.scheduleReminders(for: med)

        let medIDString = med.id?.uuidString ?? "?"
        let scheduleIDString = (med.schedules as? Set<DoseSchedule>)?
            .first?.id?.uuidString ?? "?"
        let firesISO = ISO8601DateFormatter().string(from: fireDate)
        print("[NOTIF-DEBUG] scheduled verify-rx: medID=\(medIDString), scheduleID=\(scheduleIDString), fires=\(firesISO)")
        ReminderScheduler.dumpPendingRequests()
    }

    private static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    #endif
}

extension View {
    func debugToolbar() -> some View {
        modifier(DebugToolbarModifier())
    }
}

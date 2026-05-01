import SwiftUI

enum AddStep: Int, Hashable, CaseIterable {
    case dose = 2, frequency, times, foodRule, supply, notes, review
    static let totalSteps = 8
}

final class AddMedicationState: ObservableObject {
    @Published var name: String = ""
    @Published var dose: String = ""
    @Published var pillsPerDose: Int = 1
    @Published var timesPerDay: Int = 1
    @Published var doseTimes: [Date] = [AddMedicationState.timeToday(h: 8, m: 0)]
    @Published var foodRule: String = "either"   // "with", "without", "either"
    @Published var currentSupply: Int = 30
    @Published var notes: String = ""

    @Published var path: [AddStep] = []

    func prepopulateTimes() {
        doseTimes = Self.defaultTimes(for: timesPerDay)
    }

    static func defaultTimes(for count: Int) -> [Date] {
        switch count {
        case 1: return [timeToday(h: 8, m: 0)]
        case 2: return [timeToday(h: 8, m: 0), timeToday(h: 20, m: 0)]
        case 3: return [timeToday(h: 8, m: 0), timeToday(h: 14, m: 0), timeToday(h: 20, m: 0)]
        case 4: return [timeToday(h: 8, m: 0), timeToday(h: 12, m: 0), timeToday(h: 18, m: 0), timeToday(h: 22, m: 0)]
        default:
            // Spread across waking hours, starting at 08:00.
            let clamped = max(1, min(count, 10))
            let spanMinutes = 14 * 60   // 08:00 to 22:00
            let step = spanMinutes / clamped
            return (0..<clamped).map { i in
                let total = 8 * 60 + i * step
                return timeToday(h: total / 60, m: total % 60)
            }
        }
    }

    static func timeToday(h: Int, m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    static func formatHHmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func formatDisplay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// Applies a scanned prescription to the in-flight state. Only fields
    /// whose confidence is medium or high are filled — low-confidence fields
    /// are left blank so the user types them in (B.1 S2).
    func applyScanned(_ parsed: ParsedPrescription) {
        if let value = parsed.name.value, parsed.name.confidence != .low {
            self.name = value
        }
        if let value = parsed.dose.value, parsed.dose.confidence != .low {
            self.dose = value
        }
        if let value = parsed.pillsPerDose.value, parsed.pillsPerDose.confidence != .low {
            self.pillsPerDose = value
        }
        if let freq = parsed.frequency.value, parsed.frequency.confidence != .low {
            timesPerDay = AddMedicationState.timesPerDay(fromFrequency: freq)
            prepopulateTimes()
        }
        if let value = parsed.foodRule.value, parsed.foodRule.confidence != .low {
            self.foodRule = value
        }
        if let value = parsed.quantity.value, parsed.quantity.confidence != .low {
            self.currentSupply = max(0, min(value, 200))
        }
    }

    static func timesPerDay(fromFrequency freq: String) -> Int {
        let lower = freq.lowercased()
        if lower.contains("twice") || lower.contains("2 times")        { return 2 }
        if lower.contains("three") || lower.contains("3 times")        { return 3 }
        if lower.contains("four")  || lower.contains("4 times")        { return 4 }
        if lower.contains("once")  || lower.contains("daily") ||
           lower.contains("at bedtime") || lower.contains("as needed") { return 1 }
        if lower.contains("every"),
           let regex = try? NSRegularExpression(pattern: #"every\s+(\d+)\s+hour"#,
                                                options: .caseInsensitive),
           let match = regex.firstMatch(in: lower,
                                        options: [],
                                        range: NSRange(lower.startIndex..., in: lower)),
           match.numberOfRanges >= 2 {
            let n = (lower as NSString).substring(with: match.range(at: 1))
            if let hrs = Int(n), hrs > 0, hrs <= 24 {
                return max(1, min(4, 24 / hrs))
            }
        }
        return 1
    }
}

struct AddMedicationFlow: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.supervisorTargetPersonID) private var supervisorTargetPersonID: UUID?
    @StateObject private var state = AddMedicationState()
    @Environment(\.dismiss) private var dismiss
    @State private var showPermissionBanner = false
    @State private var saveError: String?
    /// Set when the user picks a target inside the in-flow picker.
    /// Takes precedence over `supervisorTargetPersonID` only when the
    /// environment value was nil at presentation time (i.e. the
    /// dashboard didn't preselect anyone).
    @State private var pickedTargetPersonID: UUID?

    let repository: MedicationRepository
    var onSaved: () -> Void

    init(repository: MedicationRepository = MedicationRepository(), onSaved: @escaping () -> Void) {
        self.repository = repository
        self.onSaved = onSaved
    }

    /// Resolves the patient this medication will belong to:
    /// 1. The dashboard's preselected person via environment, if any.
    /// 2. The user's pick from the in-flow target picker, if shown.
    /// 3. The actor (the supervisor themselves) at save-time fallback.
    /// (1) and (2) are computed for *rendering* — does the picker
    /// belong on screen? (3) is only the save-time fallback.
    private var resolvedTargetForUI: UUID? {
        supervisorTargetPersonID ?? pickedTargetPersonID
    }

    /// Pure decision used by the body. Extracted as a static helper so
    /// the regression test (the sheet must NEVER render blank) can
    /// verify the mapping without a full SwiftUI render.
    static func shouldShowTargetPicker(
        supervisorTargetPersonID: UUID?,
        pickedTargetPersonID: UUID?
    ) -> Bool {
        supervisorTargetPersonID == nil && pickedTargetPersonID == nil
    }

    var body: some View {
        Group {
            if Self.shouldShowTargetPicker(
                supervisorTargetPersonID: supervisorTargetPersonID,
                pickedTargetPersonID: pickedTargetPersonID
            ) {
                AddMedicationTargetPicker(
                    onPick: { pickedTargetPersonID = $0 },
                    onCancel: { dismiss() }
                )
            } else {
                medicationStepsFlow
            }
        }
        .environmentObject(state)
        .task {
            let status = await ReminderScheduler.currentStatus()
            showPermissionBanner = (status == .denied)
        }
    }

    private var medicationStepsFlow: some View {
        VStack(spacing: 0) {
            if showPermissionBanner {
                PermissionBanner()
            }
            NavigationStack(path: Binding(
                get: { state.path },
                set: { state.path = $0 }
            )) {
                Step1NameView()
                    .navigationDestination(for: AddStep.self) { step in
                        switch step {
                        case .dose:      Step2DoseView()
                        case .frequency: Step3FrequencyView()
                        case .times:     Step4TimesView()
                        case .foodRule:  Step5FoodRuleView()
                        case .supply:    Step6SupplyView()
                        case .notes:     Step7NotesView()
                        case .review:    Step8ReviewView(onSave: save)
                        }
                    }
            }
            .tint(.dsPrimary)
        }
    }

    private func save() {
        guard let actor = authService.currentPerson, let actorID = actor.id else {
            saveError = "We couldn't find your profile. Please sign in again."
            return
        }
        // The supervisor dashboard sets `supervisorTargetPersonID` via the
        // environment when a supervisor is creating a medication on behalf
        // of a managed client. The in-flow picker covers the case where
        // it wasn't preselected. Final fallback is the actor — single-user
        // / device-client path.
        let targetPersonID = supervisorTargetPersonID ?? pickedTargetPersonID ?? actorID

        let trimmedNotes = state.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedules = state.doseTimes.map {
            ScheduleInput(timeOfDay: AddMedicationState.formatHHmm($0), daysOfWeek: 127)
        }
        Task {
            _ = await ReminderScheduler.requestPermissionIfNeeded()
            let status = await ReminderScheduler.currentStatus()
            print("[NOTIF-DEBUG] post-save authorization status: \(ReminderScheduler.describe(status))")

            do {
                let med = try await repository.saveMedication(
                    personID: targetPersonID,
                    actorPersonID: actorID,
                    name: state.name.trimmingCharacters(in: .whitespaces),
                    dose: state.dose.trimmingCharacters(in: .whitespaces),
                    pillsPerDose: Int16(state.pillsPerDose),
                    foodRule: state.foodRule,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    currentSupply: Int16(state.currentSupply),
                    pillPhotoData: nil,
                    schedules: schedules
                )
                ReminderScheduler.scheduleReminders(for: med)
                await MainActor.run {
                    onSaved()
                    dismiss()
                }
            } catch MedicationRepositoryError.permissionDenied {
                await MainActor.run {
                    saveError = "Only supervisors can save medications."
                }
            } catch {
                await MainActor.run {
                    saveError = "We couldn't save the medication. Please try again."
                }
            }
        }
    }
}

/// Shown as the root of `AddMedicationFlow` when neither
/// `supervisorTargetPersonID` (env) nor an in-flow pick has resolved.
/// Lets the supervisor pick the patient before the medication-detail
/// steps begin. Clients and the supervisor themselves are eligible
/// targets — supervisor doctrine matches the dashboard's existing
/// `supervisor.addmed.picker.*` flow.
struct AddMedicationTargetPicker: View {
    @EnvironmentObject var authService: AuthService

    let onPick: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    Text("supervisor.addmed.picker.title")
                        .dsBodyRegular()
                        .foregroundColor(.dsTextSecondary)
                        .padding(.bottom, DSSpacing.xs)
                    ForEach(eligibleTargets, id: \.id) { target in
                        Button(action: { if let id = target.id { onPick(id) } }) {
                            HStack(spacing: DSSpacing.md) {
                                Text(target.name ?? "")
                                    .dsBodyLarge()
                                    .foregroundColor(.dsTextPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.dsTextSecondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(DSSpacing.md)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget, alignment: .leading)
                            .background(Color.dsSurface)
                            .cornerRadius(DSSpacing.rMd)
                        }
                        .accessibilityLabel(Text(target.name ?? ""))
                    }
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("supervisor.addmed.picker.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { onCancel() }
                }
            }
        }
    }

    /// People in the care circle that can be the target of a new
    /// medication: every client (managed or device), plus the actor
    /// themself for the single-user case. Sorted with the actor last
    /// so clients dominate the list.
    private var eligibleTargets: [Person] {
        guard let actor = authService.currentPerson,
              let people = actor.careCircle?.people as? Set<Person> else { return [] }
        let clients = people
            .filter {
                $0.id != nil &&
                ($0.role == Roles.deviceClient || $0.role == Roles.managedClient)
            }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        if let actorID = actor.id, !clients.contains(where: { $0.id == actorID }) {
            return clients + [actor]
        }
        return clients
    }
}

#if DEBUG
#Preview("Flow") {
    AddMedicationFlow(
        repository: MedicationRepository(stack: CoreDataStack(inMemory: true)),
        onSaved: {}
    )
}
#endif

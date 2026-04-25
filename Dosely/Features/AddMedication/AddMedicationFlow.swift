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
    @StateObject private var state = AddMedicationState()
    @Environment(\.dismiss) private var dismiss
    @State private var showPermissionBanner = false

    let repository: MedicationRepository
    var onSaved: () -> Void

    init(repository: MedicationRepository = MedicationRepository(), onSaved: @escaping () -> Void) {
        self.repository = repository
        self.onSaved = onSaved
    }

    var body: some View {
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
        .environmentObject(state)
        .task {
            let status = await ReminderScheduler.currentStatus()
            showPermissionBanner = (status == .denied)
        }
    }

    private func save() {
        let trimmedNotes = state.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedules = state.doseTimes.map {
            ScheduleInput(timeOfDay: AddMedicationState.formatHHmm($0), daysOfWeek: 127)
        }
        Task {
            // Ask on first save only. Subsequent saves skip the prompt.
            _ = await ReminderScheduler.requestPermissionIfNeeded()
            let status = await ReminderScheduler.currentStatus()
            print("[NOTIF-DEBUG] post-save authorization status: \(ReminderScheduler.describe(status))")

            let med = await repository.saveMedication(
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
        }
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

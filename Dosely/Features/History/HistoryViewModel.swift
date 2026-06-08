import Foundation
import SwiftUI

enum TimeSlot: Int, CaseIterable, Hashable {
    case morning, noon, evening, bedtime

    var label: String {
        switch self {
        case .morning: return "Morning"
        case .noon:    return "Noon"
        case .evening: return "Evening"
        case .bedtime: return "Bedtime"
        }
    }

    var subtitle: String {
        switch self {
        case .morning: return "before 11"
        case .noon:    return "11–3"
        case .evening: return "3–8"
        case .bedtime: return "after 8"
        }
    }

    static func from(hour: Int) -> TimeSlot {
        if hour < 11 { return .morning }
        if hour < 15 { return .noon }
        if hour < 20 { return .evening }
        return .bedtime
    }

    /// End-of-slot hour (exclusive). For future-detection.
    var endHour: Int {
        switch self {
        case .morning: return 11
        case .noon:    return 15
        case .evening: return 20
        case .bedtime: return 24
        }
    }
}

enum CellStatus {
    case empty          // no dose scheduled, and not future
    case future         // no data yet because slot is in the future
    case allTaken       // green
    case someLate       // yellow (includes "some taken, some still pending")
    case missed         // red
}

struct GridCell: Identifiable {
    let id: String
    let dayIndex: Int              // 0=Mon ... 6=Sun
    let slot: TimeSlot
    let date: Date                 // midnight of this day
    let scheduledCount: Int
    let takenLogs: [DoseLog]
    let lateLogs: [DoseLog]
    let missedLogs: [DoseLog]
    let status: CellStatus
    let isToday: Bool

    var totalLoggedActions: Int {
        takenLogs.count + lateLogs.count + missedLogs.count
    }
}

struct WeekSummary {
    let takenCount: Int
    let scheduledCount: Int   // doses scheduled up to "now" in this week
    var adherencePercent: Int {
        guard scheduledCount > 0 else { return 0 }
        return Int((Double(takenCount) / Double(scheduledCount) * 100).rounded())
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var weekStart: Date
    @Published private(set) var cells: [[GridCell]] = []   // [day 0..6][slot 0..3]
    @Published private(set) var summary: WeekSummary = WeekSummary(takenCount: 0, scheduledCount: 0)
    @Published private(set) var oldestWeekStart: Date?
    @Published private(set) var isLoaded = false

    private let repository: MedicationRepository
    private var personID: UUID?
    let calendar: Calendar

    init(repository: MedicationRepository = MedicationRepository(), now: Date = Date()) {
        self.repository = repository
        var c = Calendar(identifier: .iso8601)
        c.firstWeekday = 2
        self.calendar = c
        self.weekStart = Self.weekStart(for: now, calendar: c)
    }

    var weekEnd: Date {
        calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    }

    var isCurrentWeek: Bool {
        weekStart == Self.weekStart(for: Date(), calendar: calendar)
    }

    var canGoBack: Bool {
        guard let oldest = oldestWeekStart else { return false }
        return weekStart > oldest
    }

    var canGoForward: Bool { !isCurrentWeek }

    func goBack() {
        guard canGoBack, let personID else { return }
        weekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        Task { await load(personID: personID) }
    }

    func goForward() {
        guard canGoForward, let personID else { return }
        weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        Task { await load(personID: personID) }
    }

    func load(personID: UUID, now: Date = Date()) async {
        let _sp = Perf.signposter.beginInterval("history.load")
        defer { Perf.signposter.endInterval("history.load", _sp) }
        self.personID = personID
        let meds = await repository.fetchAllMedications(for: personID)
        if let oldest = meds.compactMap({ $0.dateAdded }).min() {
            oldestWeekStart = Self.weekStart(for: oldest, calendar: calendar)
        } else {
            oldestWeekStart = Self.weekStart(for: now, calendar: calendar)
        }

        let start = weekStart
        let end = weekEnd
        let logs = await repository.fetchDoseLogs(for: nil, personID: personID,
                                                  from: start, to: end)

        // Fetch scheduled doses per weekday in this week.
        var dailyScheduled: [[(Medication, DoseSchedule)]] = []
        for day in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: day, to: start) else {
                dailyScheduled.append([]); continue
            }
            let doses = await repository.fetchScheduledDoses(for: personID, on: date)
            dailyScheduled.append(doses)
        }

        var grid: [[GridCell]] = []
        var weekTaken = 0
        var weekScheduled = 0

        for day in 0..<7 {
            guard let dayDate = calendar.date(byAdding: .day, value: day, to: start) else {
                grid.append([])
                continue
            }
            let isToday = calendar.isDate(dayDate, inSameDayAs: now)
            let scheduledForDay = dailyScheduled[day]

            var rows: [GridCell] = []
            for slot in TimeSlot.allCases {
                let scheduled = scheduledForDay.filter { (_, sched) in
                    guard let hhmm = sched.timeOfDay, let hour = Int(hhmm.split(separator: ":").first ?? "") else { return false }
                    return TimeSlot.from(hour: hour) == slot
                }

                let logsInCell = logs.filter { log in
                    guard let st = log.scheduledTime, calendar.isDate(st, inSameDayAs: dayDate) else { return false }
                    let hour = calendar.component(.hour, from: st)
                    return TimeSlot.from(hour: hour) == slot
                }

                let taken  = logsInCell.filter { $0.status == "taken" }
                let late   = logsInCell.filter { $0.status == "late" }
                let missed = logsInCell.filter { $0.status == "missed" }

                let slotEnd = calendar.date(bySettingHour: slot.endHour == 24 ? 23 : slot.endHour,
                                            minute: slot.endHour == 24 ? 59 : 0,
                                            second: 0, of: dayDate) ?? dayDate
                let isFuture = slotEnd > now
                let status: CellStatus
                if scheduled.isEmpty {
                    status = isFuture ? .future : .empty
                } else if !missed.isEmpty {
                    status = .missed
                } else if !late.isEmpty || taken.count < scheduled.count {
                    status = isFuture && taken.count == 0 && late.isEmpty ? .future : .someLate
                    // All pending in a future slot stays future; if any action has happened, mark late/partial.
                } else {
                    status = .allTaken
                }

                rows.append(GridCell(
                    id: "\(day)-\(slot.rawValue)",
                    dayIndex: day,
                    slot: slot,
                    date: dayDate,
                    scheduledCount: scheduled.count,
                    takenLogs: taken,
                    lateLogs: late,
                    missedLogs: missed,
                    status: status,
                    isToday: isToday
                ))

                if !isFuture {
                    weekScheduled += scheduled.count
                    weekTaken += taken.count
                }
            }
            grid.append(rows)
        }

        self.cells = grid
        self.summary = WeekSummary(takenCount: weekTaken, scheduledCount: weekScheduled)
        self.isLoaded = true
    }

    // Hoisted to a static (perf audit, June 8): weekLabel() allocated a fresh
    // DateFormatter on every call, and it is read twice per HistoryView render.
    // Invariant format, system default locale (does not read app_language), so
    // the shared read-only formatter preserves output exactly.
    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    func weekLabel() -> String {
        if isCurrentWeek { return "This week" }
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(Self.weekRangeFormatter.string(from: weekStart)) – \(Self.weekRangeFormatter.string(from: end))"
    }

    static func weekStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }
}

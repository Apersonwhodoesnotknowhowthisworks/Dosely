import SwiftUI

struct WeekCellDetailView: View {
    let cell: GridCell
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    if allLogs.isEmpty {
                        emptyState
                    } else {
                        ForEach(allLogs, id: \.objectID) { log in
                            row(for: log)
                        }
                    }
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close details")
                }
            }
        }
    }

    private var title: String {
        let dayName = Self.dayFormatter.string(from: cell.date)
        return "\(dayName) · \(cell.slot.label)"
    }

    private var emptyState: some View {
        VStack(spacing: DSSpacing.sm) {
            Text("No doses scheduled in this slot")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allLogs: [DoseLog] {
        (cell.takenLogs + cell.lateLogs + cell.missedLogs)
            .sorted { ($0.scheduledTime ?? .distantPast) < ($1.scheduledTime ?? .distantPast) }
    }

    private func row(for log: DoseLog) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Circle()
                .fill(color(for: log.status))
                .frame(width: 12, height: 12)
                .padding(.top, DSSpacing.xs)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(log.medication?.name ?? "Medication")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Text(detail(for: log))
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
            }
            Spacer()
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private func detail(for log: DoseLog) -> String {
        let scheduledText = log.scheduledTime.map(Self.timeFormatter.string(from:)) ?? "—"
        let statusText = (log.status ?? "").capitalized
        if log.status == "taken", let actual = log.actualTime {
            return "Scheduled \(scheduledText) · Taken at \(Self.timeFormatter.string(from: actual))"
        }
        return "Scheduled \(scheduledText) · \(statusText)"
    }

    private func color(for status: String?) -> Color {
        switch status {
        case "taken":  return .dsSuccess
        case "late":   return .dsWarning
        case "missed": return .dsDanger
        default:       return .dsTextSecondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()
}

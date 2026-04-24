import SwiftUI

struct DoseCell: View {
    let cell: GridCell
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: DSSpacing.rSm)
                .fill(fillColor)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: DSSpacing.rSm)
                        .stroke(cell.isToday ? Color.dsPrimary : Color.clear, lineWidth: 2)
                )

            if cell.scheduledCount > 1 {
                Text("\(cell.scheduledCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .offset(x: -4, y: 4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(a11yLabel)
        .accessibilityHint("Tap to see details")
    }

    private var fillColor: Color {
        switch cell.status {
        case .allTaken: return .dsSuccess
        case .someLate: return .dsWarning
        case .missed:   return .dsDanger
        case .empty, .future: return Color.gray.opacity(0.2)
        }
    }

    private var a11yLabel: String {
        let dayName = Self.dayNames[cell.dayIndex]
        let slotName = cell.slot.label.lowercased()
        let scheduled = cell.scheduledCount
        let taken = cell.takenLogs.count
        if scheduled == 0 {
            return "\(dayName) \(slotName), no doses scheduled"
        }
        let summary: String
        switch cell.status {
        case .allTaken: summary = "all taken"
        case .missed:   summary = "missed"
        case .someLate: summary = "late or partial"
        case .future:   summary = "upcoming"
        case .empty:    summary = "no doses scheduled"
        }
        return "\(dayName) \(slotName), \(taken) of \(scheduled) doses taken, \(summary)"
    }

    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
}

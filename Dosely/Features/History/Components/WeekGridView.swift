import SwiftUI

struct WeekGridView: View {
    let cells: [[GridCell]]                  // [day 0..6][slot 0..3]
    var onCellTap: (GridCell) -> Void

    private static let dayHeaders = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        GeometryReader { geo in
            let spacing = DSSpacing.xs
            let cellSize = max(
                DSSpacing.minTapTarget,
                (geo.size.width - spacing * 6) / 7
            )

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                // Day header row
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(Self.dayHeaders[i])
                            .dsCaption()
                            .foregroundColor(.dsTextSecondary)
                            .frame(width: cellSize, alignment: .center)
                    }
                }
                .accessibilityHidden(true)

                ForEach(TimeSlot.allCases, id: \.self) { slot in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        HStack(spacing: DSSpacing.xs) {
                            Text(slot.label)
                                .dsBodyRegular()
                                .foregroundColor(.dsTextPrimary)
                            Text("(\(slot.subtitle))")
                                .dsCaption()
                                .foregroundColor(.dsTextSecondary)
                        }
                        .accessibilityHidden(true)

                        HStack(spacing: spacing) {
                            ForEach(0..<7, id: \.self) { day in
                                if day < cells.count, slot.rawValue < cells[day].count {
                                    let cell = cells[day][slot.rawValue]
                                    Button(action: { onCellTap(cell) }) {
                                        DoseCell(cell: cell, size: cellSize)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Color.clear.frame(width: cellSize, height: cellSize)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Compute explicit height so the grid doesn't fight its parent.
        .frame(height: gridHeight())
    }

    private func gridHeight() -> CGFloat {
        // 1 header row + 4 slot rows, each slot row has a label + cells
        let headerHeight: CGFloat = 16 + DSSpacing.md
        let perSlot: CGFloat = 20 /* label */ + DSSpacing.xs + DSSpacing.minTapTarget + DSSpacing.md
        return headerHeight + perSlot * 4
    }
}

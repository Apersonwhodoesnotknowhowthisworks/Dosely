import SwiftUI

/// "Mom: 92% this week (23/25 doses on time)". Tappable; opens the
/// supervisor's History tab scoped to the active person.
struct AdherenceSummaryCard: View {
    let adherence: PersonAdherence
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text(L("supervisor.adherence.title"))
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)

                if adherence.scheduledCount == 0 {
                    Text(L("supervisor.adherence.empty",
                           adherence.personName as NSString))
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("supervisor.adherence.summary",
                           adherence.personName as NSString,
                           adherence.percent,
                           adherence.takenCount,
                           adherence.scheduledCount))
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    progressBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.md)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rLg)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right")
                    .foregroundColor(.dsTextSecondary)
                    .padding(.trailing, DSSpacing.md)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(adherenceA11yLabel)
        .accessibilityHint(Text("supervisor.adherence.tapforhistory"))
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.dsBackground)
                    .frame(height: 8)
                Capsule()
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(adherence.percent) / 100, height: 8)
            }
        }
        .frame(height: 8)
    }

    private var barColor: Color {
        switch adherence.percent {
        case 90...:  return .dsSuccess
        case 70..<90: return .dsWarning
        default:      return .dsDanger
        }
    }

    private var adherenceA11yLabel: Text {
        if adherence.scheduledCount == 0 {
            return Text(L("supervisor.adherence.empty",
                          adherence.personName as NSString))
        }
        return Text(L("supervisor.adherence.summary",
                      adherence.personName as NSString,
                      adherence.percent,
                      adherence.takenCount,
                      adherence.scheduledCount))
    }
}

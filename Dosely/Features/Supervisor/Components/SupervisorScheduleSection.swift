import SwiftUI

/// The schedule list under the PersonSelector. Reuses `DoseCardView` so
/// the visual language matches TodayView. When `personName` is nil we're
/// in the combined "All" view and each row shows a small per-person
/// label above the card.
struct SupervisorScheduleSection: View {
    let doses: [TodayDose]
    /// nil = "All" (combined view); each card prepends the patient name.
    let personName: String?
    let people: [Person]
    var onTake: (TodayDose) -> Void
    var onSkip: (TodayDose) -> Void
    var onLearnMore: (TodayDose) -> Void
    /// When false, secondary-supervisor mode: the per-card take / skip
    /// buttons are hidden. Learn-more stays visible.
    var showActions: Bool = true

    var body: some View {
        if doses.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: DSSpacing.md) {
                ForEach(doses) { dose in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        if personName == nil {
                            Text(personLabel(for: dose))
                                .dsCaption()
                                .foregroundColor(.dsTextSecondary)
                                .padding(.leading, DSSpacing.xs)
                        }
                        DoseCardView(
                            dose: dose,
                            onTake: { onTake(dose) },
                            onSkip: { onSkip(dose) },
                            onSnooze: {},
                            onLearnMore: { onLearnMore(dose) },
                            showActions: showActions
                        )
                    }
                }
            }
        }
    }

    private func personLabel(for dose: TodayDose) -> String {
        guard let pid = dose.medication.personID else { return "" }
        return people.first(where: { $0.id == pid })?.name ?? ""
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: DSSpacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundColor(.dsSuccess)
                .accessibilityHidden(true)
            Text(personName == nil
                 ? L("supervisor.schedule.empty.all")
                 : L("supervisor.schedule.empty.person", (personName ?? "") as NSString))
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.xl)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }
}

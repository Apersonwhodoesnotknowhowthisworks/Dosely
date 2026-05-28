import SwiftUI

/// Per-active-person actions. Hidden in the "All" view (those buttons
/// are person-specific and we don't want the supervisor to accidentally
/// add a medication to the wrong patient).
struct QuickActionsCard: View {
    var onAddMedication: () -> Void
    var onViewMedicalID: () -> Void
    var onEditMedicalID: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("supervisor.quickactions.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)

            actionRow(title: L("supervisor.quickactions.addmed"),
                      icon: "pill.fill",
                      tint: .dsPrimary,
                      action: onAddMedication)
            actionRow(title: L("emergency.medicalid.view.action"),
                      icon: "heart.text.square.fill",
                      tint: .dsPrimary,
                      action: onViewMedicalID)
            actionRow(title: L("supervisor.quickactions.medicalid"),
                      icon: "cross.case.fill",
                      tint: .dsDanger,
                      action: onEditMedicalID)
            actionRow(title: L("supervisor.quickactions.settings"),
                      icon: "gearshape.fill",
                      tint: .dsTextSecondary,
                      action: onSettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    private func actionRow(title: String,
                           icon: String,
                           tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.dsTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, DSSpacing.sm)
            .frame(minHeight: DSSpacing.minTapTarget)
        }
        .accessibilityLabel(Text(title))
    }
}

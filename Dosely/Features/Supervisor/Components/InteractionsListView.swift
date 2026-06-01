import SwiftUI

/// One interaction card — shared by the `MedicationDetailView` section and the
/// dashboard's `InteractionsListView` so both look identical. `focusDrug`, when
/// set, names the OTHER participant in the title (the per-medication context);
/// when nil, the title names both drugs (the full list).
struct InteractionCard: View {
    let interaction: DrugInteraction
    var focusDrug: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Text(titleText)
                    .dsBodyLarge()
                    .bold()
                    .foregroundColor(.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DSSpacing.sm)
                severityPill
            }

            Text(interaction.description)
                .dsBodyRegular()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            (Text("interactions.recommendation.prefix").bold()
                + Text(" ")
                + Text(interaction.recommendation))
                .dsBodyRegular()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                ReadAloudButton {
                    VoiceUtterance.interaction(
                        interaction,
                        language: currentAppLanguage(),
                        fallbackInteraction: DrugInteractionService.shared.englishInteraction(id: interaction.id)
                    )
                }
            }
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private var titleText: String {
        if let focus = focusDrug {
            let normalized = focus.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let other = interaction.drugA.lowercased() == normalized ? interaction.drugB : interaction.drugA
            return other.capitalized
        }
        return "\(interaction.drugA.capitalized) + \(interaction.drugB.capitalized)"
    }

    private var severityPill: some View {
        Text(interaction.severity.localizedName)
            .dsCaption()
            .foregroundColor(.white)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(interaction.severity.displayColor))
            .accessibilityLabel(interaction.severity.localizedName)
    }
}

/// Top-of-dashboard summary banner for the selected patient. Tint and icon
/// follow the WORST severity present — severe (danger) beats moderate (warning)
/// beats informational-only (success). Tapping pushes the full list.
struct InteractionBanner: View {
    let interactions: [DrugInteraction]

    private var worst: DrugInteraction.Severity {
        interactions.map(\.severity).max(by: { $0.rank < $1.rank }) ?? .informational
    }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: worst == .informational ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(worst.displayColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(countText)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Text("interactions.banner.tap")
                    .dsCaption()
                    .foregroundColor(.dsTextSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
        .background(worst.displayColor.opacity(0.15))
        .cornerRadius(DSSpacing.rMd)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("interactions.banner.tap"))
    }

    private var countText: String {
        interactions.count == 1
            ? L("interactions.banner.count.singular")
            : L("interactions.banner.count.plural", String(interactions.count) as NSString)
    }
}

/// Full scrollable list of every distinct interaction in the patient's
/// regimen. Pushed from the dashboard banner.
struct InteractionsListView: View {
    let interactions: [DrugInteraction]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                ForEach(interactions) { interaction in
                    InteractionCard(interaction: interaction)
                }
            }
            .padding(DSSpacing.lg)
        }
        .background(Color.dsBackground.ignoresSafeArea())
        .navigationTitle(Text("interactions.list.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

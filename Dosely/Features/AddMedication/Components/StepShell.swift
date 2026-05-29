import SwiftUI

struct StepShell<Content: View>: View {
    let stepNumber: Int
    /// Pre-localized question string. Callers pass `L("addmed.stepN.question")`.
    let question: String
    /// Pre-localized primary button title. Defaults to localized "Next".
    var primaryTitle: String? = nil
    var primaryEnabled: Bool = true
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            progress

            Text(question)
                .dsTitleLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DSSpacing.lg)

            content()
                .padding(.horizontal, DSSpacing.lg)

            Spacer(minLength: DSSpacing.lg)

            VStack(spacing: DSSpacing.sm) {
                if let secondaryTitle, let secondaryAction {
                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                            .dsBodyLarge()
                            .foregroundColor(.dsPrimary)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    }
                    .accessibilityLabel(secondaryTitle)
                }

                if primaryAction != nil {
                    let title = primaryTitle ?? L("common.next")
                    Button(action: { primaryAction?() }) {
                        Text(title)
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            // Disabled fill — adaptive system gray, not a fixed literal (see DSColors audit note).
                            .background(primaryEnabled ? Color.dsPrimary : Color.gray.opacity(0.4))
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .disabled(!primaryEnabled)
                    .accessibilityLabel(title)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.bottom, DSSpacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.dsBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(L("addmed.stepof", stepNumber, AddStep.totalSteps))
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        // Progress-track fill — adaptive system gray (see DSColors audit note).
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.dsPrimary)
                        .frame(width: geo.size.width * CGFloat(stepNumber) / CGFloat(AddStep.totalSteps), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("addmed.stepof", stepNumber, AddStep.totalSteps))
    }
}

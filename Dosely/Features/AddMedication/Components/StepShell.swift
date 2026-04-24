import SwiftUI

struct StepShell<Content: View>: View {
    let stepNumber: Int
    let question: String
    var primaryTitle: String? = "Next"
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

                if let primaryTitle, let primaryAction {
                    Button(action: primaryAction) {
                        Text(primaryTitle)
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(primaryEnabled ? Color.dsPrimary : Color.gray.opacity(0.4))
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .disabled(!primaryEnabled)
                    .accessibilityLabel(primaryTitle)
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
            Text("Step \(stepNumber) of \(AddStep.totalSteps)")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
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
        .accessibilityLabel("Step \(stepNumber) of \(AddStep.totalSteps)")
    }
}

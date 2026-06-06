import SwiftUI

/// Confirmation sheet for converting a secondary supervisor into a managed
/// family member. Extracted from `PersonDetailView` (already well over the
/// 200-line floor) and used as a sheet rather than a stock `.alert` because
/// the flow needs an in-flight loading state — the Convert button shows a
/// `ProgressView` and disables while the demotion commits, which a plain
/// `.alert` (whose buttons dismiss it on tap) cannot express. Cancel stays
/// live throughout; dismissing mid-flight is harmless — the write finishes
/// on its own.
struct DemoteToManagedClientSheet: View {
    let personName: String
    let isWorking: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    Text(L("people.demote.confirm.title", personName as NSString))
                        .dsTitleMedium()
                        .foregroundColor(.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        bodyLine(L("people.demote.confirm.body.line1", personName as NSString))
                        bodyLine(L("people.demote.confirm.body.line2"))
                        bodyLine(L("people.demote.confirm.body.line3"))
                        bodyLine(L("people.demote.confirm.body.line4"))
                        bodyLine(L("people.demote.confirm.body.line5"))
                    }

                    convertButton
                    cancelButton
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text("people.demote.section.title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func bodyLine(_ text: String) -> some View {
        Text(text)
            .dsBodyRegular()
            .foregroundColor(.dsTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var convertButton: some View {
        Button(action: onConfirm) {
            HStack(spacing: DSSpacing.sm) {
                if isWorking {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }
                Text("people.demote.confirm.button.confirm")
                    .dsBodyLarge()
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            .background(Color.dsDanger)
            .cornerRadius(DSSpacing.rMd)
        }
        .disabled(isWorking)
        .accessibilityLabel(Text("people.demote.confirm.button.confirm"))
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("people.demote.confirm.button.cancel")
                .dsBodyLarge()
                .foregroundColor(.dsPrimary)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
        }
        .accessibilityLabel(Text("people.demote.confirm.button.cancel"))
    }
}

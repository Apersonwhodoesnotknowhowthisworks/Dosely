import SwiftUI

/// Confirmation sheet for switching into a family member's view (act-as).
/// A sheet rather than a stock `.alert` for the same reason as
/// `DemoteToManagedClientSheet`: the flow needs multi-line explanation plus
/// an in-flight loading state — the confirm button shows a `ProgressView`
/// and disables while the switch lands, which a plain `.alert` (whose
/// buttons dismiss it on tap) cannot express. Shared by the People-list
/// context menu and the PersonDetailView affordance.
struct ProfileSwitchConfirmSheet: View {
    let personName: String
    let isWorking: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    Text(L("profileswitch.confirm.title", personName as NSString))
                        .dsTitleMedium()
                        .foregroundColor(.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        bodyLine(L("profileswitch.confirm.body.line1", personName as NSString))
                        bodyLine(L("profileswitch.confirm.body.line2"))
                        bodyLine(L("profileswitch.confirm.body.line3"))
                    }

                    confirmButton
                    cancelButton
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle(Text(L("profileswitch.confirm.title", personName as NSString)))
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

    private var confirmButton: some View {
        Button(action: onConfirm) {
            HStack(spacing: DSSpacing.sm) {
                if isWorking {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }
                Text(L("profileswitch.confirm.button.confirm", personName as NSString))
                    .dsBodyLarge()
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            .background(Color.dsPrimary)
            .cornerRadius(DSSpacing.rMd)
        }
        .disabled(isWorking)
        .accessibilityLabel(Text(L("profileswitch.confirm.button.confirm", personName as NSString)))
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("profileswitch.confirm.button.cancel")
                .dsBodyLarge()
                .foregroundColor(.dsPrimary)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
        }
        .accessibilityLabel(Text("profileswitch.confirm.button.cancel"))
    }

    /// Shared act-as error copy, one string per `ProfileSwitchError` case.
    /// Distinct error codes per error-collapse convention — see CLAUDE.md
    /// "Error-collapse convention" and the build_log April 30 phantom join
    /// code entry: every case gets its own copy, nothing collapses. Static
    /// here (the flow's shared UI surface) so both call sites — the People
    /// list and PersonDetailView — map identically.
    static func errorMessage(_ error: Error) -> String {
        if let err = error as? ProfileSwitchError {
            switch err {
            case .notPrimarySupervisor:  return L("profileswitch.error.notprimary")
            case .selfTargetNotAllowed:  return L("profileswitch.error.selftarget")
            case .targetNotInSameCircle: return L("profileswitch.error.notincircle")
            case .targetIneligible:      return L("profileswitch.error.ineligible")
            case .targetNotFound:        return L("profileswitch.error.notfound")
            }
        }
        return L("supervisor.person.error.generic")
    }
}

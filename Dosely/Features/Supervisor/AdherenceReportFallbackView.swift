import SwiftUI

/// Shown when the device has no Mail account configured
/// (`MailComposeView.canSendMail == false`). Presents the report text the user
/// can copy and paste into any other compose context — the rescue path so the
/// feature still works on a paired device where Mail was never set up.
struct AdherenceReportFallbackView: View {
    let reportBody: String

    @Environment(\.dismiss) private var dismiss
    @State private var copiedToastVisible = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.dsBackground.ignoresSafeArea()

                VStack(spacing: DSSpacing.md) {
                    TextEditor(text: .constant(reportBody))
                        .dsBodyRegular()
                        .disabled(true)
                        .padding(DSSpacing.sm)
                        .background(Color.dsSurface)
                        .cornerRadius(DSSpacing.rMd)
                        .accessibilityLabel(Text(reportBody))

                    Button(action: copyToClipboard) {
                        Label(L("email.fallback.copy.button"), systemImage: "doc.on.doc")
                            .dsBodyLarge()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                            .background(Color.dsPrimary)
                            .cornerRadius(DSSpacing.rMd)
                    }
                    .accessibilityLabel(Text("email.fallback.copy.button"))
                }
                .padding(DSSpacing.lg)

                if copiedToastVisible {
                    Text("email.fallback.copy.confirmation")
                        .dsBodyRegular()
                        .foregroundColor(.white)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, DSSpacing.sm)
                        .background(Color.dsTextPrimary.opacity(0.9))
                        .cornerRadius(DSSpacing.rLg)
                        .transition(.opacity)
                }
            }
            .navigationTitle(Text("email.fallback.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("email.fallback.done.button")) { dismiss() }
                        .accessibilityLabel(Text("email.fallback.done.button"))
                }
            }
        }
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = reportBody
        withAnimation(.easeInOut(duration: 0.2)) { copiedToastVisible = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { copiedToastVisible = false }
            }
        }
    }
}

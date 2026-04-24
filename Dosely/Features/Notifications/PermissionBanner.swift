import SwiftUI

struct PermissionBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: "bell.slash.fill")
                .font(.title3)
                .foregroundColor(.white)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Reminders are off")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                Text("Enable in Settings to get dose notifications.")
                    .dsBodyRegular()
                    .foregroundColor(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: ReminderScheduler.openSystemSettings) {
                Text("Settings")
                    .dsBodyRegular()
                    .foregroundColor(.dsWarning)
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.white)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Open system settings to enable notifications")
        }
        .padding(DSSpacing.md)
        .background(Color.dsWarning)
        .cornerRadius(DSSpacing.rMd)
        .padding(.horizontal, DSSpacing.md)
        .padding(.top, DSSpacing.sm)
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

/// Active alerts for the active person. Stubbed for Prompt 14; Prompt 15
/// will wire real signals (missed-dose rollups, low supply, lockout,
/// emergency button).
struct AlertsCard: View {
    let alerts: [DashboardAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "bell.fill")
                    .foregroundColor(.dsPrimary)
                    .accessibilityHidden(true)
                Text("supervisor.alerts.title")
                    .dsTitleMedium()
                    .foregroundColor(.dsTextPrimary)
            }

            if alerts.isEmpty {
                Text("supervisor.alerts.empty")
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    ForEach(alerts) { alert in
                        alertRow(alert)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
    }

    private func alertRow(_ alert: DashboardAlert) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Circle()
                .fill(severityColor(alert.severity))
                .frame(width: 10, height: 10)
                .padding(.top, DSSpacing.xs)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(alert.title)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                Text(alert.body)
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func severityColor(_ severity: DashboardAlert.Severity) -> Color {
        switch severity {
        case .info:    return .dsPrimary
        case .warning: return .dsWarning
        case .danger:  return .dsDanger
        }
    }
}

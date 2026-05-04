import SwiftUI

/// The Today tab's "Alerts" section. Reads real `Alert` rows kept
/// fresh by `SyncCoordinator`'s listener; pending alerts surface
/// above acknowledged, both groups newest-first within. Tapping
/// "Acknowledge" runs the atomic transaction in `AlertsRepository`,
/// and the listener's snapshot update propagates to every other
/// supervisor's device — the card re-renders as "Acknowledged by …"
/// for them within seconds.
struct AlertsCard: View {
    let alerts: [Alert]
    let onAcknowledge: (Alert) -> Void

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
                    ForEach(alerts, id: \.docID) { alert in
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

    // MARK: - Per-alert row

    private func alertRow(_ alert: Alert) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Image(systemName: iconName(for: alert))
                .foregroundColor(severityColor(for: alert))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(bodyText(for: alert))
                    .dsBodyRegular()
                    .foregroundColor(.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ackRow(alert)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func ackRow(_ alert: Alert) -> some View {
        if let name = alert.acknowledgedByName, !name.isEmpty {
            Text(L("supervisor.alerts.ackedby", name as NSString))
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
        } else if (alert.acknowledgedByFirebaseUID ?? "").isEmpty {
            Button(action: { onAcknowledge(alert) }) {
                Text("supervisor.alerts.ack")
                    .dsBodyRegular()
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, DSSpacing.xs)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel(Text("supervisor.alerts.ack"))
        } else {
            Text("supervisor.alerts.ackedby.unknown")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
        }
    }

    // MARK: - Type → presentation

    private func iconName(for alert: Alert) -> String {
        switch alert.type {
        case FirestoreModels.AlertType.missedDose:    return "clock.fill"
        case FirestoreModels.AlertType.emergency:     return "exclamationmark.triangle.fill"
        case FirestoreModels.AlertType.weeklySummary: return "chart.bar.fill"
        default:                                       return "bell.fill"
        }
    }

    private func severityColor(for alert: Alert) -> Color {
        switch alert.type {
        case FirestoreModels.AlertType.emergency:     return .dsDanger
        case FirestoreModels.AlertType.missedDose:    return .dsWarning
        case FirestoreModels.AlertType.weeklySummary: return .dsPrimary
        default:                                       return .dsTextSecondary
        }
    }

    private func bodyText(for alert: Alert) -> String {
        let payload = FirestoreModels.FAlert.decodePayload(alert.payloadJSON) ?? [:]
        switch alert.type {
        case FirestoreModels.AlertType.missedDose:
            let person = payload["personName"] ?? ""
            let med = payload["medicationName"] ?? ""
            let time = formattedTime(alert.scheduledTime)
            return L("supervisor.alerts.body.misseddose",
                     person as NSString,
                     time as NSString,
                     med as NSString)

        case FirestoreModels.AlertType.emergency:
            let person = payload["personName"] ?? ""
            let time = formattedTime(alert.createdAt)
            return L("supervisor.alerts.body.emergency",
                     person as NSString,
                     time as NSString)

        case FirestoreModels.AlertType.weeklySummary:
            if let summary = payload["_summary"] {
                let parts = summary.split(separator: "|").compactMap { Int($0) }
                if parts.count == 2, parts[1] > 0 {
                    let percent = Int((Double(parts[0]) / Double(parts[1]) * 100).rounded())
                    return L("supervisor.alerts.body.weeklysummary",
                             parts[0] as NSNumber,
                             parts[1] as NSNumber,
                             percent as NSNumber)
                }
            }
            return L("supervisor.alerts.body.weeklysummary.empty")

        default:
            return ""
        }
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

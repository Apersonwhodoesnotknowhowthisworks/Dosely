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
            HStack(alignment: .top, spacing: DSSpacing.sm) {
                Image(systemName: Self.iconName(for: alert))
                    .foregroundColor(Self.severityColor(for: alert))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    // Refill alerts lead with a "Refill soon: {med}" headline so
                    // the medication is named; other types are self-contained in
                    // the body line and render unchanged.
                    if alert.type == FirestoreModels.AlertType.refill {
                        Text(Self.typeTitle(for: alert, language: currentAppLanguage()))
                            .dsBodyLarge()
                            .foregroundColor(.dsTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Self.bodyText(for: alert))
                        .dsBodyRegular()
                        .foregroundColor(.dsTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ackRow(alert)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            // Speaker kept OUTSIDE the combined element above so VoiceOver can
            // focus and trigger it as its own control.
            ReadAloudButton { alertUtterance(alert) }
        }
    }

    /// Builds the readout for an alert: a short type title plus the body, with
    /// an English fallback set when the active language is Punjabi.
    private func alertUtterance(_ alert: Alert) -> VoiceUtterance {
        let lang = currentAppLanguage()
        let title = Self.typeTitle(for: alert, language: lang)
        let body = Self.bodyText(for: alert, language: lang)
        guard lang == "pa" else {
            return .alert(title: title, body: body, language: lang)
        }
        return .alert(title: title, body: body, language: lang,
                      fallbackTitle: Self.typeTitle(for: alert, language: "en"),
                      fallbackBody: Self.bodyText(for: alert, language: "en"))
    }

    @ViewBuilder
    private func ackRow(_ alert: Alert) -> some View {
        switch Self.ackState(for: alert) {
        case .acknowledged(let name):
            Text(L("supervisor.alerts.ackedby", name as NSString))
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
        case .actionable:
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
        case .acknowledgedByUnknown:
            Text("supervisor.alerts.ackedby.unknown")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
        }
    }

    // MARK: - Ack state

    /// The three mutually-exclusive states an alert's ack row can be
    /// in. Pulled out of the view body so the branch is unit-testable
    /// without walking SwiftUI's opaque UIView tree (which no longer
    /// surfaces `Text` as `UILabel`s under recent iOS).
    enum AckState: Equatable {
        case acknowledged(name: String)
        case actionable
        case acknowledgedByUnknown
    }

    static func ackState(for alert: Alert) -> AckState {
        if let name = alert.acknowledgedByName, !name.isEmpty {
            return .acknowledged(name: name)
        } else if (alert.acknowledgedByFirebaseUID ?? "").isEmpty {
            return .actionable
        } else {
            return .acknowledgedByUnknown
        }
    }

    // MARK: - Type → presentation

    static func iconName(for alert: Alert) -> String {
        switch alert.type {
        case FirestoreModels.AlertType.missedDose:    return "clock.fill"
        case FirestoreModels.AlertType.emergency:     return "exclamationmark.triangle.fill"
        case FirestoreModels.AlertType.weeklySummary: return "chart.bar.fill"
        case FirestoreModels.AlertType.refill:        return "pills.fill"
        default:                                       return "bell.fill"
        }
    }

    static func severityColor(for alert: Alert) -> Color {
        switch alert.type {
        case FirestoreModels.AlertType.emergency:     return .dsDanger
        case FirestoreModels.AlertType.missedDose:    return .dsWarning
        case FirestoreModels.AlertType.weeklySummary: return .dsPrimary
        case FirestoreModels.AlertType.refill:        return .dsWarning
        default:                                       return .dsTextSecondary
        }
    }

    /// Active-language body used by the row's `Text`. Delegates to the
    /// language-parameterized form so the display path is unchanged.
    static func bodyText(for alert: Alert) -> String {
        bodyText(for: alert, language: currentAppLanguage())
    }

    /// Renders the alert body in a SPECIFIC language. The voice readout needs
    /// both the active language and an English fallback, so this can't assume
    /// the active language the way a `Text` view can.
    static func bodyText(for alert: Alert, language: String) -> String {
        let payload = FirestoreModels.FAlert.decodePayload(alert.payloadJSON) ?? [:]
        switch alert.type {
        case FirestoreModels.AlertType.missedDose:
            let person = payload["personName"] ?? ""
            let med = payload["medicationName"] ?? ""
            let time = Self.formattedTime(alert.scheduledTime)
            return L("supervisor.alerts.body.misseddose", in: language,
                     person as NSString, time as NSString, med as NSString)

        case FirestoreModels.AlertType.emergency:
            let person = payload["personName"] ?? ""
            let time = Self.formattedTime(alert.createdAt)
            return L("supervisor.alerts.body.emergency", in: language,
                     person as NSString, time as NSString)

        case FirestoreModels.AlertType.weeklySummary:
            if let summary = payload["_summary"] {
                let parts = summary.split(separator: "|").compactMap { Int($0) }
                if parts.count == 2, parts[1] > 0 {
                    let percent = Int((Double(parts[0]) / Double(parts[1]) * 100).rounded())
                    return L("supervisor.alerts.body.weeklysummary", in: language,
                             parts[0] as NSNumber, parts[1] as NSNumber, percent as NSNumber)
                }
            }
            return L("supervisor.alerts.body.weeklysummary.empty", in: language)

        case FirestoreModels.AlertType.refill:
            let days = payload["daysRemaining"] ?? ""
            let runOut = payload["runOutDate"] ?? ""
            return L("refill.alert.body", in: language, days as NSString, runOut as NSString)

        default:
            return ""
        }
    }

    /// Short spoken title prepended to the readout ("Missed dose", "Emergency",
    /// "Weekly summary") so a listener hears the category before the detail.
    static func typeTitle(for alert: Alert, language: String) -> String {
        switch alert.type {
        case FirestoreModels.AlertType.emergency:     return L("voice.alert.title.emergency", in: language)
        case FirestoreModels.AlertType.weeklySummary: return L("voice.alert.title.weeklysummary", in: language)
        case FirestoreModels.AlertType.refill:
            let payload = FirestoreModels.FAlert.decodePayload(alert.payloadJSON) ?? [:]
            return L("refill.alert.title", in: language, (payload["medicationName"] ?? "") as NSString)
        default:                                       return L("voice.alert.title.misseddose", in: language)
        }
    }

    static func formattedTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

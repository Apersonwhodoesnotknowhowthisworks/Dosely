import Foundation

/// Renders an `AdherenceReport` into the email subject and plain-text body.
/// Plain text on purpose — a doctor pastes it straight into an EMR, and plain
/// text survives copy-paste across systems where HTML breaks.
///
/// Every label localizes via the report's `language`. Dates use that
/// language's month/day names but Latin (Western Arabic) numerals, per
/// CLAUDE.md's "Western Arabic everywhere" rule; counts and percentages use
/// `%d`, which is Latin regardless of locale.
struct AdherenceReportFormatter {
    let language: String

    func subject(for report: AdherenceReport) -> String {
        let range = "\(dateString(report.dateRange.lowerBound, "MMM d")) – "
            + dateString(report.dateRange.upperBound, "MMM d, yyyy")
        return L("email.subject.template", in: language,
                 report.patientName as NSString, range as NSString)
    }

    func plainTextBody(for report: AdherenceReport) -> String {
        var lines: [String] = []

        lines.append(L("email.body.header.title", in: language))
        lines.append(L("email.body.header.patient", in: language, report.patientName as NSString))
        lines.append(L("email.body.header.period", in: language,
                       dateString(report.dateRange.lowerBound, "MMM d, yyyy") as NSString,
                       dateString(report.dateRange.upperBound, "MMM d, yyyy") as NSString))
        lines.append(L("email.body.header.generatedby", in: language))
        lines.append("")

        lines.append(L("email.body.overall.title", in: language,
                       report.overallPercent, report.overallTakenCount, report.overallScheduledCount))
        lines.append("")

        lines.append(L("email.body.medications.heading", in: language))
        lines.append("-----------")
        for med in report.medications {
            lines.append(L("email.body.medication.line", in: language,
                           med.name as NSString, med.dose as NSString))
            lines.append(L("email.body.medication.adherence", in: language,
                           med.percent, med.takenCount, med.scheduledCount))
        }
        lines.append("")

        lines.append(L("email.body.missed.heading", in: language))
        lines.append("------------")
        if report.missedDoses.isEmpty {
            lines.append(L("email.body.missed.empty", in: language))
        } else {
            for missed in report.missedDoses {
                lines.append(L("email.body.missed.line", in: language,
                               missed.medicationName as NSString,
                               dateString(missed.scheduledAt, "MMM d, h:mm a") as NSString))
            }
        }
        lines.append("")

        lines.append("----")
        lines.append(L("email.body.disclaimer", in: language))

        return lines.joined(separator: "\n")
    }

    /// Date in the report's language with Latin numerals (`@numbers=latn`).
    private func dateString(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "\(language)@numbers=latn")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

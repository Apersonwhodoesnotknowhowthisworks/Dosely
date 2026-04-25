import SwiftUI

struct DoseCardView: View {
    let dose: TodayDose
    var onTake: () -> Void
    var onSkip: () -> Void
    var onSnooze: () -> Void
    var onLearnMore: () -> Void = {}

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            header
            if isExpanded {
                Divider()
                expandedContent
            }
        }
        .padding(DSSpacing.md)
        .frame(minHeight: 80, alignment: .top)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rLg)
        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(isExpanded ? "Double-tap to collapse" : "Double-tap for options")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            timeColumn
            medColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            trailingColumn
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var timeColumn: some View {
        Text(Self.timeFormatter.string(from: dose.scheduledDate))
            .dsTitleMedium()
            .foregroundColor(.dsTextPrimary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Scheduled for \(Self.timeFormatter.string(from: dose.scheduledDate))")
    }

    private var medColumn: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(dose.medication.name ?? "Medication")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .allowsTightening(false)
                .minimumScaleFactor(1.0)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitleText)
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: DSSpacing.sm) {
            statusDot
            actionArea
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 16, height: 16)
            .accessibilityLabel("Status: \(dose.status.rawValue)")
    }

    @ViewBuilder
    private var actionArea: some View {
        switch dose.status {
        case .upcoming:
            Button(action: onTake) {
                Text("I took it")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Mark \(dose.medication.name ?? "medication") as taken")
            .accessibilityHint("Logs this dose as taken now")

        case .taken:
            Text(takenAtText)
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .accessibilityLabel("Taken at \(takenAtText.replacingOccurrences(of: "Taken at ", with: ""))")

        case .late:
            statusLabel("Late", color: .dsWarning)
        case .missed:
            statusLabel("Missed", color: .dsDanger)
        case .skipped:
            statusLabel("Skipped", color: .dsTextSecondary)
        }
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .dsBodyRegular()
            .foregroundColor(color)
            .accessibilityLabel(text)
    }

    // MARK: - Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            if let data = dose.medication.pillPhotoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .cornerRadius(DSSpacing.rMd)
                    .accessibilityLabel("Photo of \(dose.medication.name ?? "the pill")")
            }

            if let notes = dose.medication.notes, !notes.isEmpty {
                Text(notes)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
            }

            HStack(spacing: DSSpacing.sm) {
                expandedButton("Took it",      background: .dsPrimary,  action: onTake,
                               a11y: "Log dose as taken")
                expandedButton("Skip",         background: .dsTextSecondary, action: onSkip,
                               a11y: "Skip this dose")
                expandedButton("Snooze 10 min", background: .dsWarning, action: onSnooze,
                               a11y: "Snooze this dose for ten minutes")
            }

            Button(action: onLearnMore) {
                Label("Learn more", systemImage: "info.circle")
                    .dsBodyLarge()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSSpacing.rMd)
                            .stroke(Color.dsPrimary, lineWidth: 1.5)
                    )
            }
            .accessibilityLabel("Learn more about \(dose.medication.name ?? "this medication")")
        }
    }

    private func expandedButton(
        _ title: String,
        background: Color,
        action: @escaping () -> Void,
        a11y: String
    ) -> some View {
        Button(action: action) {
            Text(title)
                .dsBodyRegular()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .background(background)
                .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel(a11y)
    }

    // MARK: - Derivations

    private var subtitleText: String {
        let pillWord = dose.medication.pillsPerDose == 1 ? "pill" : "pills"
        let count = "\(dose.medication.pillsPerDose) \(pillWord)"
        let food: String
        switch dose.medication.foodRule ?? "either" {
        case "with":    food = "with food"
        case "without": food = "without food"
        default:        food = "with or without food"
        }
        let dose = dose.medication.dose ?? ""
        if dose.isEmpty { return "\(count), \(food)" }
        return "\(dose) · \(count), \(food)"
    }

    private var statusColor: Color {
        switch dose.status {
        case .taken:   return .dsSuccess
        case .late:    return .dsWarning
        case .missed:  return .dsDanger
        case .skipped: return .dsTextSecondary
        case .upcoming: return Color.gray.opacity(0.3)
        }
    }

    private var takenAtText: String {
        guard let actual = dose.log?.actualTime else { return "Taken" }
        return "Taken at \(Self.timeFormatter.string(from: actual))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()
}

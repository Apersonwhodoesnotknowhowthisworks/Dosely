import SwiftUI

struct DoseCardView: View {
    let dose: TodayDose
    var onTake: () -> Void
    var onSkip: () -> Void
    var onSnooze: () -> Void
    var onLearnMore: () -> Void = {}
    /// When false, the take / skip / snooze buttons are hidden — used
    /// by the secondary-supervisor view to render the schedule
    /// read-only. The status dot and "Learn more" stay visible.
    var showActions: Bool = true

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
        // Elevation shadow — black, fades against a dark surface by convention (see DSColors audit note).
        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .contain)
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
        Text(timeString)
            .dsTitleMedium()
            .foregroundColor(.dsTextPrimary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var medColumn: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(dose.medication.name ?? "")
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
            HStack(spacing: DSSpacing.xs) {
                ReadAloudButton {
                    VoiceUtterance.dose(
                        medication: dose.medication.name ?? "",
                        dose: dose.medication.dose ?? "",
                        time: timeString,
                        foodRule: dose.medication.foodRule,
                        language: currentAppLanguage()
                    )
                }
                statusDot
            }
            actionArea
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actionArea: some View {
        switch dose.status {
        case .upcoming:
            if showActions {
                Button(action: onTake) {
                    Text("today.itookit")
                        .dsBodyLarge()
                        .foregroundColor(.white)
                        .padding(.horizontal, DSSpacing.md)
                        .frame(minHeight: DSSpacing.minTapTarget)
                        .background(Color.dsPrimary)
                        .cornerRadius(DSSpacing.rMd)
                }
                .accessibilityLabel(Text("today.itookit"))
            } else {
                EmptyView()
            }

        case .taken:
            Text(takenAtText)
                .dsCaption()
                .foregroundColor(.dsTextSecondary)

        case .late:
            statusLabel(L("today.late"), color: .dsWarning)
        case .missed:
            statusLabel(L("today.missed"), color: .dsDanger)
        case .skipped:
            statusLabel(L("today.skipped"), color: .dsTextSecondary)
        }
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .dsBodyRegular()
            .foregroundColor(color)
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
            }

            if let notes = dose.medication.notes, !notes.isEmpty {
                Text(notes)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
            }

            if showActions {
                HStack(spacing: DSSpacing.sm) {
                    expandedButton(L("today.tookit"),    background: .dsPrimary,       action: onTake)
                    expandedButton(L("today.skipdose"),  background: .dsTextSecondary, action: onSkip)
                    expandedButton(L("today.snooze10"),  background: .dsWarning,       action: onSnooze)
                }
            }

            Button(action: onLearnMore) {
                Label("today.learnmore", systemImage: "info.circle")
                    .dsBodyLarge()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSSpacing.rMd)
                            .stroke(Color.dsPrimary, lineWidth: 1.5)
                    )
            }
            .accessibilityLabel(Text("today.learnmore"))
        }
    }

    private func expandedButton(
        _ title: String,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .dsBodyRegular()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .background(background)
                .cornerRadius(DSSpacing.rMd)
        }
    }

    // MARK: - Derivations

    private var subtitleText: String {
        let pillWord = dose.medication.pillsPerDose == 1 ? L("today.dose.pill") : L("today.dose.pills")
        let dose = dose.medication.dose ?? ""
        let pillCount = Int(self.dose.medication.pillsPerDose)
        let key: String
        switch self.dose.medication.foodRule ?? "either" {
        case "with":    key = "today.dose.subtitle.with"
        case "without": key = "today.dose.subtitle.without"
        default:        key = "today.dose.subtitle.either"
        }
        return L(key, dose as NSString, pillCount, pillWord as NSString)
    }

    private var statusColor: Color {
        switch dose.status {
        case .taken:   return .dsSuccess
        case .late:    return .dsWarning
        case .missed:  return .dsDanger
        case .skipped: return .dsTextSecondary
        // Upcoming status — adaptive system gray (see DSColors audit note).
        case .upcoming: return Color.gray.opacity(0.3)
        }
    }

    private var takenAtText: String {
        guard let actual = dose.log?.actualTime else { return L("today.tookit") }
        return L("today.takenat", LocalizedFormatters.timeFormatter.string(from: actual) as NSString)
    }

    private var timeString: String {
        LocalizedFormatters.timeFormatter.string(from: dose.scheduledDate)
    }
}

import SwiftUI

struct MedicationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let medicationName: String
    let dose: String
    let pillPhotoData: Data?

    @State private var phase: Phase

    enum Phase {
        case loading
        case loaded(DrugSource)
        case error(message: String)
    }

    init(name: String, dose: String, pillPhotoData: Data? = nil) {
        self.medicationName = name
        self.dose = dose
        self.pillPhotoData = pillPhotoData
        self._phase = State(initialValue: .loading)
    }

    #if DEBUG
    init(name: String, dose: String, pillPhotoData: Data? = nil, phase: Phase) {
        self.medicationName = name
        self.dose = dose
        self.pillPhotoData = pillPhotoData
        self._phase = State(initialValue: phase)
    }
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    disclaimerBanner
                    header
                    content
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("Medication info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close medication details")
                }
            }
        }
        .task { await loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingState
        case .loaded(.curated(let info)):
            curatedSections(info)
        case .loaded(.dynamic(let drug, let sourceLabel)):
            dynamicSections(drug, sourceLabel: sourceLabel)
        case .loaded(.missing):
            noInfoState
        case .error(let message):
            errorState(message: message)
        }
    }

    private func loadIfNeeded() async {
        if case .loading = phase {
            await load()
        }
    }

    private func load() async {
        phase = .loading
        do {
            let source = try await DrugInfoRepository.shared.lookupAny(for: medicationName)
            phase = .loaded(source)
        } catch {
            phase = .error(message: Self.friendlyError(error))
        }
    }

    private static func friendlyError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You appear to be offline. Check your connection and try again."
            case .timedOut:
                return "The medicine info service didn't respond in time. Please try again."
            default:
                return "Couldn't reach the medicine info service. Check your connection and try again."
            }
        }
        return "Couldn't reach the medicine info service. Check your connection and try again."
    }

    // MARK: - Header

    private var disclaimerBanner: some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.dsPrimary)
                .accessibilityHidden(true)
            Text("This information is general. Always follow your doctor's specific instructions.")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            pillThumb
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(medicationName)
                    .dsTitleLarge()
                    .foregroundColor(.dsTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dose.isEmpty {
                    Text(dose)
                        .dsBodyLarge()
                        .foregroundColor(.dsTextSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var pillThumb: some View {
        Group {
            if let data = pillPhotoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "pills.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 72, height: 72)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
        .accessibilityHidden(true)
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: DSSpacing.md) {
            ProgressView().scaleEffect(1.4)
            Text("Looking up info…")
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget * 4)
        .padding(DSSpacing.lg)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading medication info")
    }

    // MARK: - Curated rendering (Tier 1)

    @ViewBuilder
    private func curatedSections(_ info: DrugInfo) -> some View {
        section(title: "What it does") {
            Text(info.whatItDoes)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }

        section(title: "How to take it") {
            Text(info.howToTake)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if hasAnyFoodGuide(info.foodGuide) {
            section(title: "Food & drink") {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    foodSubSection(label: "Safe with",
                                   items: info.foodGuide.safe,
                                   color: .dsSuccess,
                                   a11y: "Safe to take with")
                    foodSubSection(label: "Take with caution",
                                   items: info.foodGuide.caution,
                                   color: .dsWarning,
                                   a11y: "Take with caution")
                    foodSubSection(label: "Avoid",
                                   items: info.foodGuide.avoid,
                                   color: .dsDanger,
                                   a11y: "Avoid")
                }
            }
        }

        if !info.commonSideEffects.isEmpty {
            section(title: "Side effects — common") {
                bulletList(info.commonSideEffects, color: .dsTextPrimary)
            }
        }

        if !info.seriousSideEffects.isEmpty {
            section(title: "Side effects — call your doctor") {
                bulletList(info.seriousSideEffects, color: .dsDanger)
            }
        }

        sourceFooter(label: info.source, url: info.sourceUrl)
    }

    // MARK: - Dynamic rendering (Tier 2 / Tier 3)

    @ViewBuilder
    private func dynamicSections(_ drug: OpenFDADrug, sourceLabel: String) -> some View {
        sourceBadge

        if let text = drug.indications, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            labelSection(title: "What it does", body: text)
        }

        if let raw = drug.dosageAndAdministration, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let body = Self.sanitizeTakeItNow(raw)
            labelSection(title: "How to take it",
                         body: body,
                         footer: "Always follow your doctor's instructions.")
        }

        if let text = drug.adverseReactions, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            labelSection(title: "Side effects (per the label)", body: text)
        }

        if let text = drug.warnings, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            labelSection(title: "Warnings — call your doctor",
                         body: text,
                         color: .dsDanger)
        }

        sourceFooter(label: sourceLabel, url: drug.sourceURL)
    }

    private var sourceBadge: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "doc.text.fill")
                .foregroundColor(.dsWarning)
                .accessibilityHidden(true)
            Text("From openFDA (clinical label)")
                .dsCaption()
                .foregroundColor(.dsTextPrimary)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsWarning.opacity(0.15))
        .cornerRadius(DSSpacing.rMd)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func labelSection(title: String,
                              body: String,
                              footer: String? = nil,
                              color: Color = .dsTextPrimary) -> some View {
        section(title: title) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("This is the official label. Ask your pharmacist if any of this is unclear.")
                    .font(.body.italic())
                    .dynamicTypeSize(.large ... .accessibility5)
                    .foregroundColor(.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .dsBodyLarge()
                    .foregroundColor(color)
                    .fixedSize(horizontal: false, vertical: true)
                if let footer {
                    Text(footer)
                        .dsBodyRegular()
                        .foregroundColor(.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func sanitizeTakeItNow(_ s: String) -> String {
        // Belt-and-braces guard against the imperative "take it now" pattern
        // (B.1 S2). The footer caveat covers it semantically; this keeps the
        // exact phrase out of the rendered text just in case.
        s.replacingOccurrences(of: "take it now",
                               with: "take it as your doctor directs",
                               options: .caseInsensitive)
    }

    // MARK: - Section helpers

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(title)
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    @ViewBuilder
    private func foodSubSection(label: String, items: [String], color: Color, a11y: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.sm) {
                    Circle().fill(color).frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(label)
                        .dsBodyLarge()
                        .foregroundColor(.dsTextPrimary)
                        .accessibilityLabel(a11y)
                        .accessibilityAddTraits(.isHeader)
                }
                bulletList(items, color: .dsTextPrimary)
                    .padding(.leading, DSSpacing.lg)
            }
        }
    }

    private func bulletList(_ items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: DSSpacing.sm) {
                    Text("•")
                        .dsBodyLarge()
                        .foregroundColor(color)
                        .accessibilityHidden(true)
                    Text(item)
                        .dsBodyLarge()
                        .foregroundColor(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func hasAnyFoodGuide(_ guide: FoodGuide) -> Bool {
        !guide.safe.isEmpty || !guide.caution.isEmpty || !guide.avoid.isEmpty
    }

    @ViewBuilder
    private func sourceFooter(label: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("Source")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .accessibilityAddTraits(.isHeader)
            if let parsed = URL(string: url) {
                Button(action: { openURL(parsed) }) {
                    Text(label)
                        .dsBodyRegular()
                        .foregroundColor(.dsPrimary)
                        .underline()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Open source: \(label)")
                .accessibilityHint("Opens in Safari")
            } else {
                Text(label)
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
            }
        }
        .padding(.top, DSSpacing.sm)
    }

    // MARK: - Failure states

    private var noInfoState: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.dsTextSecondary)
                    .accessibilityHidden(true)
                Text("No detailed info yet")
                    .dsTitleMedium()
                    .foregroundColor(.dsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("We don't have detailed info about this medication yet. Ask your pharmacist.")
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { dismiss() }) {
                Text("Close")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Close medication details")
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(.dsDanger)
                    .accessibilityHidden(true)
                Text("Couldn't reach the medicine info service")
                    .dsTitleMedium()
                    .foregroundColor(.dsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(message)
                .dsBodyLarge()
                .foregroundColor(.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { Task { await load() } }) {
                Text("Retry")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Retry loading medication info")
        }
        .padding(DSSpacing.md)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
    }
}

// MARK: - Previews

#if DEBUG
private extension DrugInfo {
    static let metforminPreview = DrugInfo(
        nameKey: "metformin",
        commonNames: ["Metformin"],
        whatItDoes: "Lowers blood sugar in adults with type 2 diabetes.",
        howToTake: "Swallow with a meal and a full glass of water.",
        commonSideEffects: ["Upset stomach", "Diarrhea"],
        seriousSideEffects: ["Severe muscle pain", "Trouble breathing"],
        foodGuide: FoodGuide(safe: ["Most regular meals"], caution: ["Heavy alcohol use"], avoid: []),
        source: "DailyMed · U.S. National Library of Medicine",
        sourceUrl: "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query=metformin"
    )

    static let warfarinPreview = DrugInfo(
        nameKey: "warfarin",
        commonNames: ["Warfarin"],
        whatItDoes: "Thins the blood to help prevent dangerous clots.",
        howToTake: "Swallow with water once a day at the same time.",
        commonSideEffects: ["Easy bruising", "Bleeding gums"],
        seriousSideEffects: ["Heavy bleeding", "Severe headache"],
        foodGuide: FoodGuide(
            safe: ["Water"],
            caution: ["Leafy greens — keep intake steady"],
            avoid: ["Heavy alcohol use"]
        ),
        source: "DailyMed",
        sourceUrl: "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query=warfarin"
    )

    static let lengthywick = DrugInfo(
        nameKey: "lengthywick",
        commonNames: ["Lengthywick"],
        whatItDoes: String(repeating: "This medicine works through a long chain of physiological pathways and the description deliberately keeps going to test wrapping behaviour across many lines without ever being cut off. ", count: 4),
        howToTake: "Take as your doctor told you.",
        commonSideEffects: ["Mild fatigue"],
        seriousSideEffects: ["Severe rash"],
        foodGuide: FoodGuide(safe: ["Water"], caution: [], avoid: []),
        source: "DailyMed",
        sourceUrl: "https://dailymed.nlm.nih.gov/dailymed/"
    )
}

private extension OpenFDADrug {
    static let eliquisPreview = OpenFDADrug(
        brandName: "ELIQUIS",
        genericName: "APIXABAN",
        indications: "ELIQUIS is indicated to reduce the risk of stroke and systemic embolism in patients with non-valvular atrial fibrillation.",
        dosageAndAdministration: "The recommended dose is 5 mg taken orally twice daily. In patients with at least 2 of the following: age greater than or equal to 80 years, body weight less than or equal to 60 kg, or serum creatinine greater than or equal to 1.5 mg/dL, the recommended dose is 2.5 mg twice daily.",
        warnings: "Premature discontinuation of any oral anticoagulant, including ELIQUIS, increases the risk of thrombotic events. Spinal/epidural hematoma may occur in patients receiving ELIQUIS who are anticoagulated and undergoing neuraxial anesthesia or spinal puncture.",
        adverseReactions: "Most common adverse reactions (>1%) are related to bleeding.",
        sourceURL: "https://dailymed.nlm.nih.gov/dailymed/search.cfm?query=eliquis"
    )
}

#Preview("Metformin · curated") {
    MedicationDetailView(name: "Metformin", dose: "500mg",
                         phase: .loaded(.curated(.metforminPreview)))
}

#Preview("Warfarin · all food sections") {
    MedicationDetailView(name: "Warfarin", dose: "5mg",
                         phase: .loaded(.curated(.warfarinPreview)))
}

#Preview("Eliquis · openFDA dynamic") {
    MedicationDetailView(name: "Eliquis", dose: "5mg",
                         phase: .loaded(.dynamic(.eliquisPreview, sourceLabel: "openFDA · DailyMed")))
}

#Preview("Imaginary · missing") {
    MedicationDetailView(name: "Imaginary Drug", dose: "10mg",
                         phase: .loaded(.missing))
}

#Preview("Long copy · wraps") {
    MedicationDetailView(name: "Lengthywick", dose: "100mg",
                         phase: .loaded(.curated(.lengthywick)))
}

#Preview("Loading") {
    MedicationDetailView(name: "Anything", dose: "10mg", phase: .loading)
}

#Preview("Error · retry") {
    MedicationDetailView(name: "Anything", dose: "10mg",
                         phase: .error(message: "You appear to be offline. Check your connection and try again."))
}
#endif

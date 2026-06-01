import SwiftUI

struct MedicationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let medicationName: String
    let dose: String
    let pillPhotoData: Data?
    /// The patient whose other medications this view checks for interactions.
    /// nil (previews, the add-flow review) → the interactions section shows its
    /// "no known interactions" line.
    let patientPersonID: UUID?

    @State private var phase: Phase
    @State private var patientMedications: [Medication] = []

    enum Phase {
        case loading
        case loaded(DrugSource)
        case error(message: String)
    }

    init(name: String, dose: String, pillPhotoData: Data? = nil, patientPersonID: UUID? = nil) {
        self.medicationName = name
        self.dose = dose
        self.pillPhotoData = pillPhotoData
        self.patientPersonID = patientPersonID
        self._phase = State(initialValue: .loading)
    }

    #if DEBUG
    init(name: String, dose: String, pillPhotoData: Data? = nil,
         patientPersonID: UUID? = nil, phase: Phase) {
        self.medicationName = name
        self.dose = dose
        self.pillPhotoData = pillPhotoData
        self.patientPersonID = patientPersonID
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
                    interactionsSection
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
        .task(id: patientPersonID) { await loadPatientMedications() }
    }

    // MARK: - Interactions

    /// Drug interactions between this medication and the patient's others.
    /// Always rendered (even when empty) — "no known interactions" is itself
    /// useful information for the reader.
    private var interactionsSection: some View {
        let interactions = DrugInteractionService.shared.interactionsFor(
            medicationNamed: medicationName, in: patientMedications
        )
        return VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("interactions.section.title")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
            if interactions.isEmpty {
                Text("interactions.section.empty")
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(interactions) { interaction in
                    InteractionCard(interaction: interaction, focusDrug: medicationName)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadPatientMedications() async {
        guard let personID = patientPersonID else { return }
        patientMedications = await MedicationRepository().fetchAllMedications(for: personID)
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
        let parsed = OpenFDAContentParser.parse(drug)

        sourceBadge

        if let text = parsed.whatItDoes {
            labelSection(title: "What it does", body: text)
        }

        if let text = parsed.howToTake {
            labelSection(title: "How to take it", body: text)
        }

        if !parsed.commonSideEffects.isEmpty {
            bulletLabelSection(
                title: "Side effects — common",
                items: parsed.commonSideEffects,
                color: .dsTextPrimary
            )
        }

        if !parsed.warnings.isEmpty {
            bulletLabelSection(
                title: "Side effects — call your doctor",
                items: parsed.warnings,
                color: .dsDanger
            )
        }

        sourceFooter(label: sourceLabel, url: drug.sourceURL)

        if !parsed.rawFallback.isEmpty {
            fullFDATextDisclosure(parsed.rawFallback)
        }
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
                fdaLabelCaption
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

    @ViewBuilder
    private func bulletLabelSection(title: String,
                                    items: [String],
                                    color: Color) -> some View {
        section(title: title) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                fdaLabelCaption
                bulletList(items, color: color)
            }
        }
    }

    private var fdaLabelCaption: some View {
        Text("This is from the official FDA label. Ask your pharmacist if any of this is unclear.")
            .font(.body.italic())
            .dynamicTypeSize(.large ... .accessibility5)
            .foregroundColor(.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func fullFDATextDisclosure(_ fields: [String: String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                ForEach(fields.keys.sorted(), id: \.self) { label in
                    if let text = fields[label] {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(label)
                                .dsCaption()
                                .foregroundColor(.dsTextSecondary)
                                .accessibilityAddTraits(.isHeader)
                            Text(text)
                                .dsBodyRegular()
                                .foregroundColor(.dsTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, DSSpacing.sm)
        } label: {
            Text("Show full FDA text")
                .dsBodyLarge()
                .foregroundColor(.dsPrimary)
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsSurface)
        .cornerRadius(DSSpacing.rMd)
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
                BulletRow(text: item, color: color)
            }
        }
    }

    private struct BulletRow: View {
        let text: String
        let color: Color

        var body: some View {
            HStack(alignment: .top, spacing: DSSpacing.sm) {
                Text("•")
                    .dsBodyLarge()
                    .foregroundColor(color)
                    .accessibilityHidden(true)
                Text(text)
                    .dsBodyLarge()
                    .foregroundColor(color)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Realistic-shaped fixture: multi-paragraph indications, comma-list
    /// adverse reactions, semicolon-list warnings — exercises every parser
    /// strategy at once.
    static let realisticDynamicPreview = OpenFDADrug(
        brandName: "ELIQUIS",
        genericName: "APIXABAN",
        indications: """
        ELIQUIS is indicated to reduce the risk of stroke and systemic embolism in patients with non-valvular atrial fibrillation. \
        It is also used for the treatment of deep vein thrombosis (DVT) and of pulmonary embolism (PE), and for the prophylaxis of DVT after hip or knee replacement surgery.
        """,
        dosageAndAdministration: "The recommended dose is 5 mg orally twice daily. Patients meeting the dose-reduction criteria should receive 2.5 mg twice daily instead.",
        warnings: "Premature discontinuation of any oral anticoagulant increases the risk of thrombotic events; spinal or epidural hematoma may occur in patients undergoing neuraxial anesthesia; bleeding risk is elevated in patients with severe renal impairment",
        adverseReactions: "The most common adverse reactions include bleeding events, gastrointestinal disturbance, nausea, anemia, and bruising.",
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

#Preview("Eliquis · realistic openFDA shape") {
    MedicationDetailView(name: "Eliquis", dose: "5mg",
                         phase: .loaded(.dynamic(.realisticDynamicPreview, sourceLabel: "openFDA · DailyMed")))
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

#Preview("Metformin · curated · dark") {
    MedicationDetailView(name: "Metformin", dose: "500mg",
                         phase: .loaded(.curated(.metforminPreview)))
        .preferredColorScheme(.dark)
}

#Preview("Eliquis · dynamic · dark") {
    MedicationDetailView(name: "Eliquis", dose: "5mg",
                         phase: .loaded(.dynamic(.realisticDynamicPreview, sourceLabel: "openFDA · DailyMed")))
        .preferredColorScheme(.dark)
}
#endif

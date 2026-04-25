import SwiftUI

struct MedicationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let medicationName: String
    let dose: String
    let pillPhotoData: Data?
    let info: DrugInfo?

    init(name: String, dose: String, pillPhotoData: Data? = nil) {
        self.medicationName = name
        self.dose = dose
        self.pillPhotoData = pillPhotoData
        self.info = DrugInfoRepository.shared.lookupInfo(for: name)
    }

    #if DEBUG
    init(name: String, dose: String, pillPhotoData: Data? = nil, info: DrugInfo?) {
        self.medicationName = name
        self.dose = dose
        self.pillPhotoData = pillPhotoData
        self.info = info
    }
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    disclaimerBanner
                    header
                    if let info {
                        sections(for: info)
                    } else {
                        noInfoState
                    }
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

    // MARK: - Sections

    @ViewBuilder
    private func sections(for info: DrugInfo) -> some View {
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

        sourceFooter(info: info)
    }

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
    private func sourceFooter(info: DrugInfo) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("Source")
                .dsCaption()
                .foregroundColor(.dsTextSecondary)
                .accessibilityAddTraits(.isHeader)
            if let url = URL(string: info.sourceUrl) {
                Button(action: { openURL(url) }) {
                    Text(info.source)
                        .dsBodyRegular()
                        .foregroundColor(.dsPrimary)
                        .underline()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Open source: \(info.source)")
                .accessibilityHint("Opens in Safari")
            } else {
                Text(info.source)
                    .dsBodyRegular()
                    .foregroundColor(.dsTextSecondary)
            }
        }
        .padding(.top, DSSpacing.sm)
    }

    // MARK: - No-info state

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
}

// MARK: - Previews

#if DEBUG
#Preview("Metformin · full") {
    MedicationDetailView(
        name: "Metformin",
        dose: "500mg",
        pillPhotoData: nil
    )
}

#Preview("Warfarin · full food guide") {
    MedicationDetailView(
        name: "Warfarin",
        dose: "5mg"
    )
}

#Preview("Imaginary · no info") {
    MedicationDetailView(
        name: "Imaginary Drug",
        dose: "10mg",
        pillPhotoData: nil,
        info: nil
    )
}

#Preview("Long whatItDoes · wraps") {
    MedicationDetailView(
        name: "Lengthywick",
        dose: "100mg",
        pillPhotoData: nil,
        info: DrugInfo(
            nameKey: "lengthywick",
            commonNames: ["Lengthywick"],
            whatItDoes: String(repeating: "This medicine works through a long chain of physiological pathways and the description deliberately keeps going to test wrapping behavior across many lines without ever being cut off. ", count: 4),
            howToTake: "Take as your doctor told you.",
            commonSideEffects: ["Mild fatigue", "Headache"],
            seriousSideEffects: ["Severe rash"],
            foodGuide: FoodGuide(safe: ["Water"], caution: [], avoid: []),
            source: "DailyMed · U.S. National Library of Medicine",
            sourceUrl: "https://dailymed.nlm.nih.gov/dailymed/"
        )
    )
}
#endif

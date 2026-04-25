import SwiftUI

struct ScanReviewView: View {
    let parsed: ParsedPrescription
    let image: UIImage
    var onContinue: (ParsedPrescription) -> Void
    var onRetry: () -> Void
    var onTypeIt: () -> Void

    @State private var name: String
    @State private var dose: String
    @State private var frequency: String
    @State private var foodRule: String
    @State private var quantity: String

    init(parsed: ParsedPrescription,
         image: UIImage,
         onContinue: @escaping (ParsedPrescription) -> Void,
         onRetry: @escaping () -> Void,
         onTypeIt: @escaping () -> Void) {
        self.parsed = parsed
        self.image = image
        self.onContinue = onContinue
        self.onRetry = onRetry
        self.onTypeIt = onTypeIt
        self._name      = State(initialValue: parsed.name.value      ?? "")
        self._dose      = State(initialValue: parsed.dose.value      ?? "")
        self._frequency = State(initialValue: parsed.frequency.value ?? "")
        self._foodRule  = State(initialValue: parsed.foodRule.value  ?? "")
        self._quantity  = State(initialValue: parsed.quantity.value.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    thumbnail
                    field("Medication name", text: $name, confidence: parsed.name.confidence)
                    field("Dose", text: $dose, confidence: parsed.dose.confidence)
                    field("How often", text: $frequency, confidence: parsed.frequency.confidence)
                    field("With or without food", text: $foodRule, confidence: parsed.foodRule.confidence)
                    field("Quantity", text: $quantity, confidence: parsed.quantity.confidence,
                          keyboard: .numberPad)

                    primaryButton
                    secondaryButton
                    tertiaryButton
                }
                .padding(DSSpacing.lg)
            }
            .background(Color.dsBackground.ignoresSafeArea())
            .navigationTitle("Review scan")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var thumbnail: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 140)
            .frame(maxWidth: .infinity)
            .background(Color.dsSurface)
            .cornerRadius(DSSpacing.rMd)
            .accessibilityLabel("Photo of the prescription label")
    }

    @ViewBuilder
    private func field(_ label: String,
                       text: Binding<String>,
                       confidence: FieldConfidence,
                       keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                confidenceIcon(confidence)
                Text(label)
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
            }
            TextField(label, text: text)
                .dsBodyLarge()
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .padding(DSSpacing.md)
                .frame(minHeight: DSSpacing.minTapTarget)
                .background(Color.dsSurface)
                .cornerRadius(DSSpacing.rMd)
                .accessibilityLabel(label)
                .accessibilityHint(accessibilityHint(for: confidence))

            switch confidence {
            case .medium:
                Text("Please double-check")
                    .dsCaption()
                    .foregroundColor(.dsWarning)
            case .low:
                Text("We couldn't read this — please type it in")
                    .dsCaption()
                    .foregroundColor(.dsDanger)
            case .high:
                EmptyView()
            }
        }
        .padding(DSSpacing.md)
        .background(Color.dsBackground)
    }

    private func confidenceIcon(_ confidence: FieldConfidence) -> some View {
        Image(systemName: iconName(confidence))
            .foregroundColor(iconColor(confidence))
            .accessibilityHidden(true)
    }

    private func iconName(_ c: FieldConfidence) -> String {
        switch c {
        case .high:   return "checkmark.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low:    return "xmark.octagon.fill"
        }
    }

    private func iconColor(_ c: FieldConfidence) -> Color {
        switch c {
        case .high:   return .dsSuccess
        case .medium: return .dsWarning
        case .low:    return .dsDanger
        }
    }

    private func accessibilityHint(for confidence: FieldConfidence) -> String {
        switch confidence {
        case .high:   return "We're confident this is correct."
        case .medium: return "Please double-check this value."
        case .low:    return "We couldn't read this. Please type it in."
        }
    }

    // MARK: - Buttons

    private var primaryButton: some View {
        Button(action: { onContinue(currentParsed) }) {
            Text("Looks good, continue")
                .dsBodyLarge()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .background(Color.dsPrimary)
                .cornerRadius(DSSpacing.rMd)
        }
        .accessibilityLabel("Continue with the scanned data")
    }

    private var secondaryButton: some View {
        Button(action: onRetry) {
            Text("Try again")
                .dsBodyLarge()
                .foregroundColor(.dsPrimary)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                .overlay(
                    RoundedRectangle(cornerRadius: DSSpacing.rMd)
                        .stroke(Color.dsPrimary, lineWidth: 1.5)
                )
        }
        .accessibilityLabel("Retake the photo")
    }

    private var tertiaryButton: some View {
        Button(action: onTypeIt) {
            Text("Type it in instead")
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
                .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
        }
        .accessibilityLabel("Skip the scan and type the medication manually")
    }

    // MARK: - Output

    private var currentParsed: ParsedPrescription {
        var result = parsed
        let trimmed: (String) -> String? = { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        result.name      = ParsedField(value: trimmed(name),
                                       confidence: parsed.name.confidence)
        result.dose      = ParsedField(value: trimmed(dose),
                                       confidence: parsed.dose.confidence)
        result.frequency = ParsedField(value: trimmed(frequency),
                                       confidence: parsed.frequency.confidence)
        result.foodRule  = ParsedField(value: trimmed(foodRule),
                                       confidence: parsed.foodRule.confidence)
        result.quantity  = ParsedField(value: Int(quantity.trimmingCharacters(in: .whitespaces)),
                                       confidence: parsed.quantity.confidence)
        return result
    }
}

#if DEBUG
#Preview("Review · all high") {
    ScanReviewView(
        parsed: ParsedPrescription(
            name: ParsedField(value: "Metformin", confidence: .high),
            dose: ParsedField(value: "500mg", confidence: .high),
            frequency: ParsedField(value: "Twice daily", confidence: .high),
            foodRule: ParsedField(value: "with", confidence: .high),
            quantity: ParsedField(value: 60, confidence: .medium),
            pillsPerDose: ParsedField(value: 1, confidence: .high),
            rawLines: []
        ),
        image: UIImage(systemName: "doc.text") ?? UIImage(),
        onContinue: { _ in }, onRetry: {}, onTypeIt: {}
    )
}

#Preview("Review · mixed confidence") {
    ScanReviewView(
        parsed: ParsedPrescription(
            name: ParsedField(value: "Lisinopri", confidence: .medium),
            dose: ParsedField(value: nil, confidence: .low),
            frequency: ParsedField(value: "Once daily", confidence: .high),
            foodRule: ParsedField(value: nil, confidence: .low),
            quantity: ParsedField(value: nil, confidence: .low),
            pillsPerDose: .empty,
            rawLines: []
        ),
        image: UIImage(systemName: "doc.text") ?? UIImage(),
        onContinue: { _ in }, onRetry: {}, onTypeIt: {}
    )
}
#endif

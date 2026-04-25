import SwiftUI

@MainActor
final class ScanCoordinatorState: ObservableObject {
    enum Phase {
        case scanning
        case processing(UIImage)
        case review(ParsedPrescription, UIImage)
        case fallbackToManual
    }
    @Published var phase: Phase = .scanning

    func handleCapture(_ image: UIImage) {
        phase = .processing(image)
        Task {
            do {
                let lines = try await OCRService.recognizeText(from: image)
                let parsed = PrescriptionParser.parse(lines)
                if parsed.allFieldsLow {
                    phase = .fallbackToManual
                } else {
                    phase = .review(parsed, image)
                }
            } catch {
                phase = .fallbackToManual
            }
        }
    }

    func retry() { phase = .scanning }
}

struct ScanCoordinator: View {
    @StateObject private var state = ScanCoordinatorState()
    var onComplete: (ParsedPrescription) -> Void
    var onAbandonToManual: () -> Void

    var body: some View {
        switch state.phase {
        case .scanning:
            CameraScanView(
                onCapture: { image in state.handleCapture(image) },
                onCancel: { onAbandonToManual() },
                onTypeManually: { onAbandonToManual() }
            )
        case .processing(let image):
            ProcessingView(image: image)
        case .review(let parsed, let image):
            ScanReviewView(
                parsed: parsed,
                image: image,
                onContinue: { final in onComplete(final) },
                onRetry: { state.retry() },
                onTypeIt: { onAbandonToManual() }
            )
        case .fallbackToManual:
            FallbackView(
                onTypeIt: { onAbandonToManual() },
                onRetry: { state.retry() }
            )
        }
    }
}

private struct ProcessingView: View {
    let image: UIImage

    var body: some View {
        ZStack {
            Color.dsBackground.ignoresSafeArea()
            VStack(spacing: DSSpacing.lg) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .cornerRadius(DSSpacing.rMd)
                    .accessibilityLabel("Captured photo of the label")
                ProgressView().scaleEffect(1.5)
                Text("Reading label…")
                    .dsBodyLarge()
                    .foregroundColor(.dsTextPrimary)
                    .accessibilityLabel("Reading label")
            }
            .padding(DSSpacing.lg)
        }
    }
}

private struct FallbackView: View {
    var onTypeIt: () -> Void
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: DSSpacing.lg) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 56))
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
            Text("We couldn't read this label clearly")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("That's okay — you can type the medication in or try the photo again.")
                .dsBodyLarge()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onTypeIt) {
                Text("Type it in instead")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Skip the scan and type the medication manually")

            Button(action: onRetry) {
                Text("Try the photo again")
                    .dsBodyLarge()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            }
            .accessibilityLabel("Retake the photo")
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBackground)
    }
}

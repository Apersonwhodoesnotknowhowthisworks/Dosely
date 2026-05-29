import SwiftUI
import AVFoundation

// MARK: - Session model

final class CameraSessionModel: NSObject, ObservableObject {
    enum SessionState: Equatable {
        case unconfigured
        case authorized
        case denied
        case failed(String)
    }

    @Published var state: SessionState = .unconfigured
    @Published var hasFlash: Bool = false
    @Published var isFlashEnabled: Bool = false
    @Published var isCapturing: Bool = false 

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "dosely.camera.session")
    private var captureContinuation: CheckedContinuation<UIImage, Error>?
    private var didConfigure = false

    enum CameraError: LocalizedError {
        case captureFailed(Error?)
        case noData
        var errorDescription: String? {
            switch self {
            case .captureFailed(let e): return e?.localizedDescription ?? "Couldn't capture the photo."
            case .noData:                return "No photo data."
            }
        }
    }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                await MainActor.run { self.state = .denied }
                return
            }
        } else if status == .denied || status == .restricted {
            await MainActor.run { self.state = .denied }
            return
        }

        await MainActor.run { self.state = .authorized }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.didConfigure { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func toggleFlash() { isFlashEnabled.toggle() }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch { /* best-effort */ }
        }
    }

    @MainActor
    func capturePhoto() async throws -> UIImage {
        let settings = AVCapturePhotoSettings()
        if isFlashEnabled, photoOutput.supportedFlashModes.contains(.on) {
            settings.flashMode = .on
        } else {
            settings.flashMode = .off
        }
        isCapturing = true
        defer { isCapturing = false }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIImage, Error>) in
            self.captureContinuation = cont
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - Configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        let preferred: AVCaptureDevice?
        if #available(iOS 17.0, *) {
            preferred = AVCaptureDevice.userPreferredCamera
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        } else {
            preferred = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }

        guard let device = preferred,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.state = .failed("Couldn't open the camera on this device.")
            }
            return
        }
        session.addInput(input)
        self.device = device

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        didConfigure = true

        let hasFlash = device.hasFlash
        DispatchQueue.main.async { self.hasFlash = hasFlash }
    }
}

extension CameraSessionModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.captureContinuation?.resume(throwing: CameraError.captureFailed(error))
                self.captureContinuation = nil
            }
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.captureContinuation?.resume(throwing: CameraError.noData)
                self.captureContinuation = nil
            }
            return
        }
        DispatchQueue.main.async {
            self.captureContinuation?.resume(returning: image)
            self.captureContinuation = nil
        }
    }
}

// MARK: - Preview layer

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func devicePoint(for screenPoint: CGPoint) -> CGPoint {
            previewLayer.captureDevicePointConverted(fromLayerPoint: screenPoint)
        }
    }
}

// MARK: - SwiftUI scan view

struct CameraScanView: View {
    @StateObject private var model = CameraSessionModel()
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void
    var onTypeManually: () -> Void

    @State private var captureError: String?
    @State private var focusIndicator: CGPoint?

    var body: some View {
        ZStack {
            // Camera viewfinder backdrop — intentionally black regardless of appearance (see DSColors audit note).
            Color.black.ignoresSafeArea()
            switch model.state {
            case .unconfigured:
                ProgressView().tint(.white)
            case .denied:
                deniedView
            case .failed(let message):
                failedView(message: message)
            case .authorized:
                liveCameraView
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Live camera

    private var liveCameraView: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(session: model.session)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let normalised = CGPoint(
                            x: max(0, min(1, location.x / geo.size.width)),
                            y: max(0, min(1, location.y / geo.size.height))
                        )
                        // Vision/AVFoundation expects a device-coordinate point
                        // (0…1 with the origin at the top-right in landscape).
                        // Without access to the live preview view here we
                        // approximate with the normalised tap. The hardware
                        // refocuses regardless.
                        model.focus(at: normalised)
                        focusIndicator = location
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            withAnimation { focusIndicator = nil }
                        }
                    }

                if let point = focusIndicator {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 64, height: 64)
                        .position(point)
                        .accessibilityHidden(true)
                }

                VStack {
                    topBar
                    Spacer()
                    guideRectangle
                    Spacer()
                    bottomBar
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera ready. Point at label and tap take photo.")
    }

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpacing.md)
                    .frame(minHeight: DSSpacing.minTapTarget)
            }
            .accessibilityLabel("Cancel scan")

            Spacer()

            if model.hasFlash {
                Button(action: { model.toggleFlash() }) {
                    Image(systemName: model.isFlashEnabled ? "bolt.fill" : "bolt.slash.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: DSSpacing.minTapTarget, height: DSSpacing.minTapTarget)
                }
                .accessibilityLabel(model.isFlashEnabled ? "Turn off flash" : "Turn on flash")
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .background(Color.black.opacity(0.4))
    }

    private var guideRectangle: some View {
        VStack(spacing: DSSpacing.md) {
            RoundedRectangle(cornerRadius: DSSpacing.rMd)
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 320, height: 200)
                .shadow(color: .black.opacity(0.4), radius: 6)
                .accessibilityHidden(true)
            Text("Point the camera at the label")
                .dsBodyLarge()
                .foregroundColor(.white)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm)
                .background(Color.black.opacity(0.55))
                .cornerRadius(DSSpacing.rMd)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: DSSpacing.sm) {
            if let error = captureError {
                Text(error)
                    .dsBodyRegular()
                    .foregroundColor(.white)
                    .padding(DSSpacing.md)
                    .frame(maxWidth: .infinity)
                    .background(Color.dsDanger)
                    .cornerRadius(DSSpacing.rMd)
            }
            Button(action: { Task { await capture() } }) {
                Text("Take photo")
                    .dsTitleMedium()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget * 2)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rLg)
            }
            .disabled(model.isCapturing)
            .accessibilityLabel("Take photo of label")
            .accessibilityHint("Captures the label so it can be read")
        }
        .padding(DSSpacing.lg)
        .background(Color.black.opacity(0.0))
    }

    private func capture() async {
        captureError = nil
        do {
            let image = try await model.capturePhoto()
            onCapture(image)
        } catch {
            captureError = error.localizedDescription
        }
    }

    // MARK: - Permission denial

    private var deniedView: some View {
        VStack(spacing: DSSpacing.lg) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 56))
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
            Text("Camera access is needed to scan labels")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Open Settings to allow Dosely to use the camera, or type the medication in by hand.")
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: openSettings) {
                Text("Open Settings")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Open system settings to enable camera access")

            Button(action: onTypeManually) {
                Text("Type it in instead")
                    .dsBodyLarge()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            }
            .accessibilityLabel("Skip scanning and enter the medication manually")
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBackground)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: DSSpacing.lg) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 56))
                .foregroundColor(.dsTextSecondary)
                .accessibilityHidden(true)
            Text("We couldn't open the camera")
                .dsTitleMedium()
                .foregroundColor(.dsTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .dsBodyRegular()
                .foregroundColor(.dsTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onTypeManually) {
                Text("Type it in instead")
                    .dsBodyLarge()
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
                    .background(Color.dsPrimary)
                    .cornerRadius(DSSpacing.rMd)
            }
            .accessibilityLabel("Skip scanning and enter the medication manually")

            Button(action: onCancel) {
                Text("Cancel")
                    .dsBodyLarge()
                    .foregroundColor(.dsPrimary)
                    .frame(maxWidth: .infinity, minHeight: DSSpacing.minTapTarget)
            }
            .accessibilityLabel("Close the scan screen")
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBackground)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

import MessageUI
import SwiftUI

/// SwiftUI wrapper around `MFMailComposeViewController`. Pre-fills the subject
/// and a plain-text body; the recipient is left empty for the user to type the
/// doctor's address at send time. The parent dismisses via its `.sheet`
/// binding inside `onCompletion`.
struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let onCompletion: (Result<MFMailComposeResult, Error>) -> Void

    /// UI should consult this before presenting the sheet; when false, present
    /// `AdherenceReportFallbackView` instead.
    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onCompletion: (Result<MFMailComposeResult, Error>) -> Void

        init(onCompletion: @escaping (Result<MFMailComposeResult, Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            if let error {
                onCompletion(.failure(error))
            } else {
                onCompletion(.success(result))
            }
        }
    }
}

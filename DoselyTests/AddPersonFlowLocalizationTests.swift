import XCTest
import SwiftUI
@testable import Dosely

/// Two complementary guards for the "raw key showed up in the UI" bug
/// on the People → "Add a family member" chooser.
///
/// The shipping bug had two ingredients. The keys
/// `supervisor.add.{managed,device,supervisor}.{title,blurb}` were all
/// present in `en.lproj`. But `AddPersonFlow.AddType.titleKey` /
/// `.blurbKey` are runtime `String` values, and the chooser passed
/// them straight to `Text(_:)`. When `Text` is given a `String` it
/// binds to the verbatim initializer and renders the key literally.
/// `Text(LocalizedStringKey(...))` or routing through `L()` is what
/// actually localizes a runtime key.
///
/// The first batch of tests probes the lookup table directly: every
/// key the chooser references must resolve to something other than
/// itself in `en.lproj`. That catches the user's original hypothesis
/// (a missing key) for any future addition.
///
/// The second test renders the chooser in a `UIHostingController` and
/// walks the resulting UIKit hierarchy for any visible label whose
/// text equals one of the raw keys. That catches the actual shipped
/// bug (key resolves correctly, but the call site bypassed
/// localization).
@MainActor
final class AddPersonFlowLocalizationTests: XCTestCase {
    /// Every key the chooser screen references at render time. Test
    /// failures here read cleanly — the assertion message names the
    /// missing key — so add a row whenever a new chooser type lands.
    private let chooserKeys: [String] = [
        "supervisor.add.managed.title",
        "supervisor.add.managed.blurb",
        "supervisor.add.device.title",
        "supervisor.add.device.blurb",
        "supervisor.add.supervisor.title",
        "supervisor.add.supervisor.blurb"
    ]

    // MARK: - Lookup table coverage

    /// `NSLocalizedString` returns the key verbatim when the key is
    /// missing from every `.lproj`. This is the single most common
    /// failure mode for "raw key showed up in the UI" — a string was
    /// referenced from code but never added to `Localizable.strings`.
    /// We probe the English bundle directly so this passes regardless
    /// of the active runtime language.
    func test_chooserKeysAllResolve_inEnglishBundle() throws {
        guard let url = Bundle(for: type(of: self)).url(forResource: "en", withExtension: "lproj"),
              let englishBundle = Bundle(url: url) else {
            // Fall back to the main bundle for the en-by-default case.
            for key in chooserKeys {
                let resolved = NSLocalizedString(key, comment: "")
                XCTAssertNotEqual(resolved, key,
                                  "Key \"\(key)\" is missing from Localizable.strings — NSLocalizedString returned the key verbatim")
            }
            return
        }
        for key in chooserKeys {
            let resolved = englishBundle.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(resolved, key,
                              "Key \"\(key)\" is missing from en.lproj/Localizable.strings — bundle returned the key verbatim")
        }
    }

    // MARK: - Render check

    /// Renders the chooser step and asserts no visible label text
    /// equals one of the raw keys. Catches the `Text(String)` trap
    /// where the key resolves in the bundle but the call site never
    /// asked for localization.
    func test_chooserRender_doesNotShowRawLocalizationKeys() {
        let view = AddPersonFlow(
            personRepo: PersonRepository(stack: CoreDataStack(inMemory: true)),
            careCircleRepo: CareCircleRepository(stack: CoreDataStack(inMemory: true)),
            onAdded: {}
        )
        .environmentObject(AuthService())

        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let visible = Self.collectVisibleText(in: controller.view)

        for key in chooserKeys {
            XCTAssertFalse(visible.contains(key),
                           "Chooser is rendering raw localization key \"\(key)\" — likely a Text(String) call that should be Text(L(...)) or Text(LocalizedStringKey(...))")
        }
    }

    // MARK: - Helpers

    private static func collectVisibleText(in view: UIView) -> [String] {
        var found: [String] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            found.append(text)
        }
        if let textView = view as? UITextView, !textView.text.isEmpty {
            found.append(textView.text)
        }
        for sub in view.subviews {
            found.append(contentsOf: collectVisibleText(in: sub))
        }
        return found
    }
}

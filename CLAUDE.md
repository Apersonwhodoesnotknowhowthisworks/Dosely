# Dosely — project context

## What it is

Dosely is a native iOS medication tracker aimed at elderly users. The primary client is the developer's grandparents (65+), who currently take 4 daily medications and frequently miss doses. Every design and engineering decision should be judged against that user: readable at arm's length, forgiving of mistakes, usable with shaky hands and imperfect eyesight.

## Tech stack

- **UI:** SwiftUI, iOS 16.0 minimum
- **Persistence:** Core Data (offline-first; the app must be fully functional without network)
- **Reminders:** UNUserNotificationCenter with local notifications
- **Auth (optional sign-in for caregivers / cross-device sync):** Firebase Auth
- **Label scanning:** Vision framework (on-device OCR)
- **Accessibility / voice readout:** AVSpeechSynthesizer
- **Language:** Swift 5+

## Design system

Located in `Dosely/DesignSystem/`. Use these tokens everywhere — do not hardcode colors, fonts, or spacing values elsewhere in the app.

- **`DSColors.swift`** — semantic color tokens on `Color` (sRGB hex literals).
  - `Color.dsPrimary` `#2B6CB0`, `Color.dsSuccess` `#2F855A`, `Color.dsWarning` `#D69E2E`, `Color.dsDanger` `#C53030`
  - `Color.dsBackground` `#F7FAFC`, `Color.dsSurface` white
  - `Color.dsTextPrimary` `#1A202C`, `Color.dsTextSecondary` `#4A5568`
- **`DSTypography.swift`** — semantic font tokens + `View` modifiers, all scaling with Dynamic Type (`.large ... .accessibility5`).
  - `.dsTitleLarge()` (`.largeTitle`, bold), `.dsTitleMedium()` (`.title2`, semibold)
  - `.dsBodyLarge()` — 18pt floor for elderly users (B.1 U1); use for any body copy the grandparents read
  - `.dsBodyRegular()` (`.body`), `.dsCaption()` (`.caption`)
- **`DSSpacing.swift`** — layout constants on `DSSpacing`.
  - Spacing: `xs 4`, `sm 8`, `md 16`, `lg 24`, `xl 32`, `xxl 48`
  - Corner radius: `rSm 8`, `rMd 12`, `rLg 16`
  - `DSSpacing.minTapTarget = 48` — WCAG 2.5.5 floor (B.1 U2); every tappable control must meet this
- **`DesignSystemPreview.swift`** — visual reference view with `#Preview` blocks; run in Xcode to eyeball tokens at default and accessibility type sizes.

## Must-have features (MVP)

- 3-tap dose logging from the home screen (open app → pick med → confirm)
- Local reminder notifications per medication schedule
- History grid showing taken / missed / skipped doses over time
- Large text throughout, respecting Dynamic Type
- Full VoiceOver support with meaningful labels on every interactive element
- Food and drug-interaction guide (static content bundled with the app for MVP)
- Offline-first: every core flow works with no network connectivity
- Emergency Medical ID screen (allergies, conditions, emergency contact) accessible from lock-adjacent entry point
- First-launch medical disclaimer the user must acknowledge before using the app

## Should-have features (post-MVP, same codebase)

- Vision-framework OCR label scan to pre-fill new medication entries
- Drug interaction lookup via the openFDA API
- Voice readout of doses and instructions (AVSpeechSynthesizer)
- Email-a-doctor flow (compose a formatted adherence report)
- Refill warnings based on pill count and schedule
- Face ID / biometric login for the caregiver view

## Out of scope for MVP

- Multi-language localization (English only for MVP)
- Symptom journal / side-effect tracking
- Full supervisor / family notification list (push to multiple caregivers on missed doses)

## Coding conventions

- SwiftUI views stay under 200 lines; extract subviews aggressively
- State via `@Observable` (iOS 17+) or `ObservableObject` (iOS 16 fallback) — no singletons for mutable state
- Core Data for all local persistence; no UserDefaults for domain data
- No force unwraps (`!`) in production code paths; use `guard let` / `if let`
- Minimal comments — only where the *why* is non-obvious
- Every interactive element has an `.accessibilityLabel` and, where relevant, `.accessibilityHint`
- Respect Dynamic Type: prefer semantic fonts (`.title`, `.body`) over fixed point sizes

## Workflow

- Every change commits to git with a descriptive message
- The app is tested on a real iPhone, not just the simulator — simulator passes are not proof of correctness for this audience (touch targets, Dynamic Type, VoiceOver, haptics all behave differently on device)

## Localization

- **Languages shipped:** English (`en`), Punjabi/Gurmukhi (`pa`). `pa` is a must-have because the primary client's first language is Punjabi.
- **String files:** `Dosely/Resources/en.lproj/Localizable.strings` (+`.stringsdict` for plurals), and the `pa.lproj` mirror. Drug-info corpus is in `Dosely/Resources/drug_info.json` (English) and `Dosely/Resources/drug_info_pa.json`.
- **Runtime switching:** Bundle swizzle. `Dosely/Localization/LocalizationBundle.swift` overrides `Bundle.main.localizedString(forKey:value:table:)` to look in the `.lproj` whose code matches `UserDefaults.standard.string(forKey: "app_language")`. The app's `body` is stamped with `.id(language)` so SwiftUI rebuilds the entire tree when the user flips language. No restart required. (The alternative — show a "Restart Dosely to apply" alert — was judged worse for elderly users.)
- **First-launch picker:** `LanguagePickerView` shows on first run, gated by `@AppStorage("language_picked")`. Settings ▸ Language re-presents the same picker.
- **Numbers:** Western Arabic everywhere (1, 2, 3) regardless of language. Older Punjabi-Canadian readers in BC are accustomed to Latin numerals; Gurmukhi numerals add cognitive load. Enforced via `Locale(identifier: "<lang>@numbers=latn")` in `LocalizedFormatters`.
- **OCR (label scanner):** English only. Apple's Vision framework does **not** support Gurmukhi for text recognition through iOS 18, so the scan flow stays in English with a Punjabi caption ("ਲੇਬਲ ਅੰਗਰੇਜ਼ੀ ਵਿੱਚ ਪੜ੍ਹਿਆ ਜਾਵੇਗਾ") under the Scan button when language is `pa`.
- **Voice readout:** `VoiceReadoutHelper.swift` is a minimal wrapper around `AVSpeechSynthesizer`. Speaks `pa-IN` for Punjabi, `en-US` for English. If no voice is installed for the requested language, logs `[VOICE-DEBUG]` and silently no-ops. Full `VoiceReadoutService` lands in a later accessibility prompt.
- **Translation review:** every Punjabi string in `pa.lproj/Localizable.strings` is AI-generated draft. The fluent-speaker checklist lives at `docs/translations_review.md`. **Do not ship to clients before review.**

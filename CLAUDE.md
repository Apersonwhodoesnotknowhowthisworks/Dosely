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

Placeholder — to be filled in during Prompt 1 (typography scale, color tokens, spacing, tap-target sizes, component library).

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

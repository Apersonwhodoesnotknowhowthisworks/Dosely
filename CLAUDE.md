# Dosely — project context

## What it is

Dosely is a native iOS medication tracker aimed at elderly users. The primary client is the developer's grandparents (65+), who currently take 4 daily medications and frequently miss doses. Every design and engineering decision should be judged against that user: readable at arm's length, forgiving of mistakes, usable with shaky hands and imperfect eyesight.

## Tech stack

- **UI:** SwiftUI, iOS 16.0 minimum
- **Source of truth (shared family data):** Cloud Firestore — care circles, people, medications, dose schedules, dose logs, and reserved subcollections (medical profiles, alerts, family contacts) all live here.
- **Local cache + offline-first:** Core Data, populated by Firestore listeners. Reads stay synchronous from Core Data so the UI is instant; writes go to Firestore first and mirror to Core Data on success.
- **Reminders:** UNUserNotificationCenter with local notifications
- **Auth:** Firebase Auth
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

## Architecture: Firestore + Core Data hybrid

- **Firestore is the source of truth** for everything shared across a care circle: the `CareCircle` doc itself, plus `people/`, `medications/`, `doseSchedules/`, `doseLogs/`, and the reserved `medicalProfiles/`, `alerts/`, `familyContacts/` subcollections under `/careCircles/{careCircleID}`. Document ids match the Core Data UUIDs so an id is meaningful in either layer.
- **Top-level `/joinCodes/{code}`** documents are a reverse-lookup index — joining a circle by code is one direct document fetch, not a collection scan, so it works for circles never seen on the joining device.
- **Core Data is a local cache.** Repository reads return Core Data objects synchronously (instant UI). Repository writes go to Firestore first; on success they mirror the change into Core Data immediately. The `SyncCoordinator` (started by `AuthService.resolveCurrentPerson`) attaches Firestore listeners that keep Core Data in sync with remote changes from another supervisor's device.
- **Atomic multi-document writes use Firestore transactions or batches.** `regenerateJoinCode` runs in a single transaction across `/careCircles/{id}.joinCode`, `/joinCodes/{old}` (delete), `/joinCodes/{new}` (create); `createCareCircle` writes both `/careCircles/{id}` and `/joinCodes/{code}` in a batch; `deleteMedication` cascades schedules + logs in a batch.
- **Offline behaviour.** The Firestore SDK queues writes locally and replays them when the network returns. Adding a med while offline succeeds locally and syncs on reconnect; logging a dose while offline does the same. Listener resubscription is automatic. The "All scheduled doses today" view continues working from Core Data with no network at all — that's the key promise of the architecture.
- **No FCM push notifications.** Free Apple Developer signing does not support Firebase Cloud Messaging push, so cross-device updates only land while a supervisor's app is foreground or recently active (Firestore listener while open). A second supervisor whose app is backgrounded will see the latest state on next foreground. Documented as a known limitation; addressed only if/when a paid signing certificate becomes available.
- **One-shot upload migration (`FirestoreUploadMigration.runIfNeeded`)** runs the first Firestore-aware launch on a device with pre-existing local-only data. It detects "local CareCircle exists but `/careCircles/{id}` does not" and uploads the entire local snapshot in one batch. Idempotent via `UserDefaults["firestore_upload_v1_complete"]`. Auto-runs from `AuthService.resolveCurrentPerson`.
- **Security rules.** Currently the dev default in `firestore.rules` (any authenticated user can read/write anything). They are locked down in Prompt 17 before any real medical data goes near a device — do not test against production Firestore until that ships.

### Firebase emulator (for local tests)

The Firestore-backed tests run against the local emulator, not against the real Firebase project. To run them:

```
brew install firebase-cli           # one-time
firebase emulators:start            # in a terminal, leave running
```

Configuration lives in `firebase.json`, `firestore.rules`, and `firestore.indexes.json` at the repo root. `FirestoreService.useEmulator(host:port:)` points the SDK at `127.0.0.1:8080` for the test target. Tests that need the emulator log a clear skip and pass when the emulator is unreachable, so CI without the emulator does not break the suite.

## Account model

Dosely organises users into **CareCircles**: small groups (a family, a household) that share a roster of `Person` rows. Every Medication and DoseLog belongs to exactly one Person. This shape is in the codebase from day one even though the supervisor dashboard and profile picker UI ship later.

- **Entities (Core Data, lightweight migration safe):**
  - **`CareCircle`** — `id: UUID`, `name: String`, `joinCode: String?` (6-digit numeric, regenerable), `createdAt: Date`. Has-many `Person` via the `members` relationship.
  - **`Person`** — `id: UUID`, `name: String`, `photoData: Data?`, `role: String`, `languagePreference: String`, `pinHash: Data?`, `pinSalt: Data?`, `failedPinAttempts: Int16`, `firebaseUID: String?`, belongs-to `CareCircle`.
  - **`Medication`** gains `personID: UUID?` (the patient who takes it; required at app layer, optional in schema for migration).
  - **`DoseLog`** gains `loggedByPersonID: UUID?` (whoever tapped "I took it" — supervisor, client, or notification action).

- **Roles (`Person.role` is a string; the canonical values are):**
  - `"supervisor"` — a Firebase-authenticated caregiver. Can create/edit/delete medications for any Person in the same circle, reset PINs, regenerate join codes, and log doses.
  - `"device_client"` — a non-Firebase user who unlocks the device profile with a 4-digit PIN (e.g. a grandparent who shares the iPad). Can log their own doses; cannot create or edit medications.
  - `"managed_client"` — a non-Firebase user with no PIN, fully managed by a supervisor (e.g. a bedridden patient). Same permissions as `device_client`: can be the *target* of medications and dose logs, but cannot author them.

- **Permission rules (enforced at the repository layer, not the UI):**
  - `MedicationRepository.saveMedication / deleteMedication` requires `actor.role == "supervisor"` and throws `MedicationRepositoryError.permissionDenied` otherwise.
  - `MedicationRepository.logDose` accepts any `loggedByPersonID` — clients log their own doses; the actor identity is captured for audit.
  - `PersonRepository.resetPin` requires the acting Person to be a supervisor in the **same** care circle as the target; cross-circle resets throw `PersonRepositoryError.permissionDenied`.
  - The repository checks the role by reading the actor's `Person` directly from the Core Data context — it does not depend on `PersonRepository`, so there is no circular dependency.

- **PIN hashing:** PBKDF2-SHA256 via CommonCrypto's `CCKeyDerivationPBKDF`. CryptoKit's PBKDF2 is not in the iOS 16 public API surface, so we use CommonCrypto. Parameters: 100,000 iterations, 32-byte derived key, 16-byte per-Person random salt generated with `SystemRandomNumberGenerator`. Salt is stored on the `Person` row alongside the hash. Verification is constant-time. Plaintext PINs are never persisted, never logged, never round-tripped. Three consecutive wrong PINs flips a lockout flag (`failedPinAttempts >= 3`); a successful verification resets the counter.

- **Join codes:** 6-digit numeric (`"%06d"` of a `0..<1_000_000` draw). On `createCareCircle` and `regenerateJoinCode` we draw with collision retry against existing circles. Birthday-paradox math: ~39% chance of *any* collision in 1000 draws, so the test threshold is "≥950 unique" rather than "all unique" — a degenerate RNG would produce far more collisions.

- **One-shot migration (`CareCircleMigration.runIfNeeded`):** runs the first time a Firebase user signs in after the refactor. Creates a default "My Family" circle, inserts the user as the founding supervisor, and stamps every existing Medication and DoseLog (which lack `personID` / `loggedByPersonID`) with that supervisor's id. Idempotent via `UserDefaults["circle_migration_v1_complete"]`. Auto-runs from `AuthService.resolveCurrentPerson` so users land on a working `currentPerson` without any UI bootstrap. The supervisor dashboard and profile picker (Prompts 14 and 15) replace the auto-bootstrap with proper UX.

- **Leaving and rejoining a circle (`CareCircleRepository.leaveCircle`):** deletes the supervisor's `Person` row from the circle. The Firebase account stays alive; on the next sign-in (or after the active flow finishes its join step) `resolveCurrentPerson` returns nil and AuthGate routes back to `CircleSetupView`. **Known limitation:** rejoining the same circle with the same Firebase account creates a *new* `Person` row — historical dose logs that referenced the old `Person.id` are not re-attributed. Settings → Family ▸ "Leave family and join another" is the user-visible entry point; rejoin-the-same-family is an edge case the MVP does not optimise for.

- **Cross-device sync:** real, via Firestore. `joinCareCircle` resolves the 6-digit code through `/joinCodes/{code}` so a second supervisor on a different device joins the same circle without ever having seen it before. While both supervisors' apps are open, changes propagate within ~5 seconds via Firestore listeners. Backgrounded apps see the latest state on next foreground (no FCM push — see the architecture section). The previous handed-down-iPad fallback (a Core Data-only join when Firestore is unreachable) is preserved in `joinCareCircle` for true offline scenarios.

## Localization

- **Languages shipped:** English (`en`), Punjabi/Gurmukhi (`pa`). `pa` is a must-have because the primary client's first language is Punjabi.
- **String files:** `Dosely/Resources/en.lproj/Localizable.strings` (+`.stringsdict` for plurals), and the `pa.lproj` mirror. Drug-info corpus is in `Dosely/Resources/drug_info.json` (English) and `Dosely/Resources/drug_info_pa.json`.
- **Runtime switching:** Bundle swizzle. `Dosely/Localization/LocalizationBundle.swift` overrides `Bundle.main.localizedString(forKey:value:table:)` to look in the `.lproj` whose code matches `UserDefaults.standard.string(forKey: "app_language")`. The app's `body` is stamped with `.id(language)` so SwiftUI rebuilds the entire tree when the user flips language. No restart required. (The alternative — show a "Restart Dosely to apply" alert — was judged worse for elderly users.)
- **First-launch picker:** `LanguagePickerView` shows on first run, gated by `@AppStorage("language_picked")`. Settings ▸ Language re-presents the same picker.
- **Numbers:** Western Arabic everywhere (1, 2, 3) regardless of language. Older Punjabi-Canadian readers in BC are accustomed to Latin numerals; Gurmukhi numerals add cognitive load. Enforced via `Locale(identifier: "<lang>@numbers=latn")` in `LocalizedFormatters`.
- **OCR (label scanner):** English only. Apple's Vision framework does **not** support Gurmukhi for text recognition through iOS 18, so the scan flow stays in English with a Punjabi caption ("ਲੇਬਲ ਅੰਗਰੇਜ਼ੀ ਵਿੱਚ ਪੜ੍ਹਿਆ ਜਾਵੇਗਾ") under the Scan button when language is `pa`.
- **Voice readout:** `VoiceReadoutHelper.swift` is a minimal wrapper around `AVSpeechSynthesizer`. Speaks `pa-IN` for Punjabi, `en-US` for English. If no voice is installed for the requested language, logs `[VOICE-DEBUG]` and silently no-ops. Full `VoiceReadoutService` lands in a later accessibility prompt.
- **Translation review:** every Punjabi string in `pa.lproj/Localizable.strings` is AI-generated draft. The fluent-speaker checklist lives at `docs/translations_review.md`. **Do not ship to clients before review.**

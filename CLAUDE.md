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

### Error-collapse convention (project-wide)

Repositories MUST surface distinct error cases — `.permissionDenied`, `.offline`, `.notFound`, `.unknown(String)` — up to the UI. Never collapse a rules rejection into `.offline` (and never the reverse). The four-case taxonomy lives on `FirestoreServiceError`; each repo defines its own domain error mirroring the same shape and translates one-to-one in its `catch` chain. UI catch sites then branch on the case and show distinct copy: "you don't have access" for `.permissionDenied`, "check your connection" for `.offline`, etc. Permission-denied messaged as a connection error sends supervisors chasing a network bug that doesn't exist.

This convention exists because the same trap shipped four separate times in April–May 2026 — regenerateJoinCode (`c3018c2`), joinCareCircle (`1f6455c`), medical-ID save (this prompt), and at least one other I'm forgetting. Every catch site that maps Firestore errors carries a comment referencing this section so the next reader sees the rule. `FirestoreServiceError.map` writes unmapped errors to `Logger(subsystem: "com.medication.dosely", category: "firestore")` so a future "what tripped this" investigation doesn't need Xcode attached.

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
- **Security rules.** Locked down in `firestore.rules` with role-based access — see "Firestore security model" below.

### Firebase emulator (for local tests)

The Firestore-backed tests run against the local emulator, not against the real Firebase project. To run them:

```
brew install firebase-cli           # one-time
firebase emulators:start            # in a terminal, leave running
```

Configuration lives in `firebase.json`, `firestore.rules`, and `firestore.indexes.json` at the repo root. `FirestoreService.useEmulator(host:port:)` points the SDK at `127.0.0.1:8080` for the test target. Tests that need the emulator log a clear skip and pass when the emulator is unreachable, so CI without the emulator does not break the suite.

## Firestore security model

- **Rules live in `/firestore.rules`** and are deployed via the Firebase CLI (`scripts/deploy_rules.sh` → `firebase deploy --only firestore:rules`). They are not part of the Xcode build — an iOS build will not push or validate them. After editing the rules, run the deploy script before testing against the live project.
- **Membership index: `/userMemberships/{firebaseUID}`.** Firestore rules can `get()` a document by full path but cannot run queries, so role-based gating needs an index keyed by Firebase UID. Each authenticated member of a circle has one of these docs: `{ careCircleID, personID, role, joinedAt, joinCode? }`. The Person doc remains canonical; the membership doc is the lookup that turns `request.auth.uid` into a `personID` so the rules can find the Person doc and read its role. `joinCode` is set at create time by joiners only — the rules verify it against `/joinCodes/{code}` as proof that the joiner had a valid code; the field is dead weight after create but harmless.
- **Trust requires consistency.** Every role check verifies BOTH the membership doc and the Person doc, and that `Person.firebaseUID == request.auth.uid`. An attacker who poisons their own `/userMemberships` with someone else's `personID` fails the firebaseUID check; an attacker who tries to write a Person doc directly fails the bootstrap rule (which requires a matching `/userMemberships`).
- **Bootstrap is sequential, not single-batch.** Founder createCareCircle: write `/careCircles/{id}` with `supervisorCount=0` → write `/joinCodes/{code}` → write `/userMemberships/{founderUID}` → write the founder's Person doc → bump `supervisorCount` to 1. Joiner is the same minus the careCircle/joinCodes writes. Trying to do all five in a single batch fails because the careCircle update rule requires the writer to already be a supervisor pre-batch.
- **`CareCircle.supervisorCount`** is a denormalized counter maintained by the app via `FieldValue.increment(±1)`. It powers the rules-layer last-supervisor protection: deleting a Person doc whose `role == "supervisor"` requires the careCircle's `supervisorCount` to be atomically decremented in the same batch (`getAfter` check) and the post-batch count must be `>= 1`. Sole-supervisor leave is impossible at the rules layer — the count cannot drop below 1 without also breaking the rule.
- **`leaveCircle` and `removePersonFromCircle` (supervisor target)** must use the atomic batch in `FirestoreService.removeSupervisorAtomically(circleID:personID:firebaseUID:)`: it deletes the Person doc, decrements `supervisorCount`, and deletes the `/userMemberships` doc together. Rules see the consistent post-batch state via `getAfter`.
- **`/joinCodes/{code}` reads** are allowed for any signed-in user (this is how a new aunt finds a circle to join from a code shared out-of-band). Writes (create/delete) require the careCircle's `joinCode` field to match the path's `{code}` AND either `supervisorCount==0` (founder bootstrap) or `isSupervisor` (regenerate). Updates to existing `/joinCodes` docs are forbidden — regenerate is delete-old + create-new in one transaction.
- **`/familyContacts/*`** — supervisors of either flavour can read; only the primary writes. The docs hold external phone numbers and emails of doctors/pharmacies that should not be visible to clients.
- **Person doc self-edit** allows only `languagePreference`, `pinHash`, `pinSalt`, and `lastModified`. Everything else (role, firebaseUID, name, failedPinAttempts) is primary-supervisor-only.
- **Tests live in `/tests/firestore_rules.test.ts`** and run via `cd tests && npm test` (boots the emulator) or `npm run test:ci` (assumes a long-running emulator on `127.0.0.1:8080`). They use `@firebase/rules-unit-testing` and the project id `demo-no-project` to match the no-arg `firebase emulators:start`. Kept out of the iOS test target so an Xcode build does not require Node.

### Primary / secondary supervisor split

The `"supervisor"` role is split into two flavours:

- **`"primary_supervisor"`** — full read/write authority over the circle. Exactly one per circle at all times. The founder of a circle is primary by default; new joiners are secondary.
- **`"secondary_supervisor"`** — read-only across the circle. Can still create alerts (e.g. emergency button) and acknowledge alerts that involve them. Everything else (medications, schedules, people, join code, family contacts) is denied.

`CareCircle.primarySupervisorPersonID` is the source of truth for who the primary is. The role string on the Person doc must agree (rules verify both). The role on `/userMemberships/{uid}` is informational — the rules read role from the Person doc, not the membership doc — so a brief stale state during promotion or migration is harmless.

The legacy `"supervisor"` value still exists in code as `Roles.legacySupervisor`. Reads (both Swift and the rules' `isPrimary` / `isAnySupervisor` helpers) treat it as `primary_supervisor` so deployed clients keep working through the rolling rollout of `PrimaryRoleMigration`. **Post-split code never writes `"supervisor"`** — `Roles.primarySupervisor` and `Roles.secondarySupervisor` are the only valid write values.

### Promotion (`promoteToPrimary`)

A primary can hand the role off to a secondary in the same circle. `PersonRepository.promoteToPrimary(targetPersonID:actorPersonID:)` calls `FirestoreService.applyPrimaryAssignment`, which writes a single Firestore batch:

1. `careCircles/{id}.primarySupervisorPersonID = newPrimary`
2. The current primary's Person doc → `role = "secondary_supervisor"`
3. The target's Person doc → `role = "primary_supervisor"`
4. The current primary's `/userMemberships/{uid}.role` → `"secondary_supervisor"`
5. The target's `/userMemberships/{uid}.role` → `"primary_supervisor"`

The rules helper `isPromotionBatch(circleID, personID)` recognizes this exact shape on a Person doc role update — it allows the demote and promote rows when the CareCircle's `primarySupervisorPersonID` is changing in the same batch and the actor is currently primary. The `/userMemberships` update rule has been broadened so a primary can update *any* membership in their circle (not just self-edit) — that's what makes the cross-actor membership writes pass.

A secondary calling `promoteToPrimary` is rejected app-side (`PersonRepositoryError.notCurrentPrimary`) and rules-side (`isPromotionBatch` requires the actor to currently be primary).

### Primary-leave protection

A primary cannot leave the circle directly while secondaries exist — `CareCircleRepository.leaveCircle` returns `.primaryMustPromoteFirst`, and the rules-layer Person-delete rule rejects deleting the current primary unless `primarySupervisorPersonID` changes to someone else in the same batch. The user-visible flow: primary opens People → tap a secondary → "Make primary supervisor" → confirm. They become secondary. They can now leave. (A sole supervisor leaving still hits the existing `lastSupervisor` check.)

### Migration: `PrimaryRoleMigration.runIfNeeded`

Runs once per device, gated by `UserDefaults["primary_role_migration_v1"]`. For every local CareCircle without a `primarySupervisorPersonID`:

- Picks the supervisor whose `Person.id.uuidString` sorts first as primary. Deterministic across devices, so concurrent migrations from two devices converge on the same answer without coordination.
- **PHASE A**: backfills the caller's own `/userMemberships` index doc via `FirestoreService.ensureMembership` (a single `setData(merge: true)` write). Production data from earlier app versions sometimes has a Person doc without a corresponding `/userMemberships` — under the new role-aware rules that locks the supervisor out (`memberOf` returns false → every read denied with "Missing or insufficient permissions"). PHASE A self-heals that state. The membership create rule's branch (d) — "self-backfill: Person doc proves authority" — recognises this case: when the requester's auth.uid matches a Person doc with a supervisor role at the claimed circle/personID path, the membership index can be safely re-created.
- **PHASE B**: writes a single Firestore batch via `applyPrimaryAssignment`: stamps `primarySupervisorPersonID`, sets the chosen primary's role to `primary_supervisor` and everyone else's to `secondary_supervisor`, mirrors role onto each `/userMemberships` (using `setData(merge: true)` so other supervisors with missing memberships get created too — the actor is now primary post-PHASE-A, so branch (c) of the membership create rule allows it).
- Mirrors the result into Core Data so the UI updates without waiting on the SyncCoordinator listener.

The two phases cannot fold into a single batch: the CareCircle and Person update rules need `isPrimary`, which depends on a pre-batch `/userMemberships`. Adding `isPrimaryAfter` to the Person update rule would let a secondary supervisor self-promote in one batch (write their own `/userMemberships` role to `primary_supervisor` + their Person.role to `primary_supervisor` — both gated only by the post-batch state) — explicitly a security hole. The two-phase split keeps Person.role mutations gated by the *pre-batch* `/userMemberships` evaluation while still letting legacy supervisors recover.

Runs from `AuthService.resolveCurrentPerson` after `FirestoreUploadMigration`, with the user's Firebase UID passed in so PHASE A targets the right membership doc. New circles created post-split set `primarySupervisorPersonID` directly at create time, so the migration is a no-op for them.

## Account model

Dosely organises users into **CareCircles**: small groups (a family, a household) that share a roster of `Person` rows. Every Medication and DoseLog belongs to exactly one Person. This shape is in the codebase from day one even though the supervisor dashboard and profile picker UI ship later.

- **Entities (Core Data, lightweight migration safe):**
  - **`CareCircle`** — `id: UUID`, `name: String`, `joinCode: String?` (6-digit numeric, regenerable), `createdAt: Date`, `primarySupervisorPersonID: UUID?` (current primary; nil only on pre-`PrimaryRoleMigration` data). Has-many `Person` via the `members` relationship.
  - **`Person`** — `id: UUID`, `name: String`, `photoData: Data?`, `role: String`, `languagePreference: String`, `pinHash: Data?`, `pinSalt: Data?`, `failedPinAttempts: Int16`, `firebaseUID: String?`, belongs-to `CareCircle`.
  - **`Medication`** gains `personID: UUID?` (the patient who takes it; required at app layer, optional in schema for migration).
  - **`DoseLog`** gains `loggedByPersonID: UUID?` (whoever tapped "I took it" — supervisor, client, or notification action).

- **Roles (`Person.role` is a string; canonical values defined in `Roles.swift`):**
  - `"primary_supervisor"` — Firebase-authenticated caregiver with full read/write. Exactly one per circle. Can create/edit/delete medications, reset PINs, regenerate join codes, log doses, and promote a secondary to primary (which atomically demotes the current primary).
  - `"secondary_supervisor"` — Firebase-authenticated caregiver, read-only across the circle. Can still create alerts and acknowledge alerts about themselves. Cannot edit medications, people, or circle settings.
  - `"device_client"` — a non-Firebase user who unlocks the device profile with a 4-digit PIN. Can log their own doses; cannot create or edit medications.
  - `"managed_client"` — a family member fully managed by a supervisor. **May have a Firebase identity** (a former supervisor who was demoted via `demoteSupervisorToManagedClient`, or a patient who signed up but doesn't want supervisor privileges) **OR may have no Firebase identity** (fully passive — the supervisor logs on their behalf). When the managed_client has a Firebase identity, they can sign in to view their own dose schedule and authorize their own dose logs (same as a `device_client` minus the PIN unlock step), and they retain a `/userMemberships` index doc (role `managed_client`) so the resolver routes them to their own view. The supervisor can always log doses on behalf of any managed_client regardless of identity status. A managed_client never authors medications or circle changes.
  - `"supervisor"` (legacy) — pre-split data. Treated as `primary_supervisor` on the read side only; never written by post-split code.

- **Permission rules (enforced at the repository layer + Firestore rules):**
  - `MedicationRepository.saveMedication / deleteMedication` and `PersonRepository.removePersonFromCircle / resetPin / updatePersonRole / createDeviceClient / createManagedClient` all require `PersonRepository.canWrite(actorPersonID:)` (true only for the primary) and throw `permissionDenied` otherwise.
  - `MedicationRepository.logDose` rejects secondary supervisors silently (returns nil); device clients and managed clients logging their *own* doses (the medication must belong to them) and the primary logging on a client's behalf all succeed. The same own-dose scoping is enforced in the Firestore dose-log create rule.
  - `PersonRepository.promoteToPrimary(targetPersonID:actorPersonID:)` requires the actor to be the current primary (`notCurrentPrimary` otherwise) and the target to be a supervisor in the same circle (`invalidPromotionTarget` otherwise).
  - `CareCircleRepository.renameCircle / regenerateJoinCode` require the actor to be primary; throw `CareCircleEditError.permissionDenied` otherwise.
  - `CareCircleRepository.leaveCircle` rejects a primary leaving directly with `.primaryMustPromoteFirst` when secondaries exist; the existing `.lastSupervisor` still applies to a sole supervisor.
  - The repository checks the role by reading the actor's `Person` directly from the Core Data context — it does not depend on `PersonRepository`, so there is no circular dependency.

- **PIN hashing:** PBKDF2-SHA256 via CommonCrypto's `CCKeyDerivationPBKDF`. CryptoKit's PBKDF2 is not in the iOS 16 public API surface, so we use CommonCrypto. Parameters: 100,000 iterations, 32-byte derived key, 16-byte per-Person random salt generated with `SystemRandomNumberGenerator`. Salt is stored on the `Person` row alongside the hash. Verification is constant-time. Plaintext PINs are never persisted, never logged, never round-tripped. Three consecutive wrong PINs flips a lockout flag (`failedPinAttempts >= 3`); a successful verification resets the counter.

- **Join codes:** 6-digit numeric (`"%06d"` of a `0..<1_000_000` draw). On `createCareCircle` and `regenerateJoinCode` we draw with collision retry against existing circles. Birthday-paradox math: ~39% chance of *any* collision in 1000 draws, so the test threshold is "≥950 unique" rather than "all unique" — a degenerate RNG would produce far more collisions.

- **One-shot migration (`CareCircleMigration.runIfNeeded`):** runs the first time a Firebase user signs in after the refactor. Creates a default "My Family" circle, inserts the user as the founding supervisor, and stamps every existing Medication and DoseLog (which lack `personID` / `loggedByPersonID`) with that supervisor's id. Idempotent via `UserDefaults["circle_migration_v1_complete"]`. Auto-runs from `AuthService.resolveCurrentPerson` so users land on a working `currentPerson` without any UI bootstrap. The supervisor dashboard and profile picker (Prompts 14 and 15) replace the auto-bootstrap with proper UX.

- **One-shot migration (`PrimaryRoleMigration.runIfNeeded`):** runs once per device after the primary/secondary split lands. Sweeps every local CareCircle that has no `primarySupervisorPersonID`, picks the lowest-UUID supervisor as primary (deterministic so concurrent devices converge on the same answer), and writes a single Firestore batch via `FirestoreService.applyPrimaryAssignment` that stamps `primarySupervisorPersonID`, sets the primary's role to `primary_supervisor` and everyone else's to `secondary_supervisor`, and mirrors role onto each `/userMemberships`. Gated by `UserDefaults["primary_role_migration_v1"]`. Auto-runs from `AuthService.resolveCurrentPerson` after `FirestoreUploadMigration`. See the "Primary / secondary supervisor split" section under "Firestore security model" for the rules-layer details.

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

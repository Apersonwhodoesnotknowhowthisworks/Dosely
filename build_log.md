# Dosely — Build Log

What actually happened, when, and what I learned. Written as I went.

## April 23 — Prompts 0–6: MVP scaffold

Six prompts back-to-back after the Canva session, Claude Code in VS Code with Auto mode on. Built the bones of the app: Xcode project hand-authored without XcodeGen, design system (DSColors / DSTypography 18pt floor for elderly users / DSSpacing 48pt minTapTarget), Core Data with Medication / DoseSchedule / DoseLog and a tested MedicationRepository (11 cases, iPhone 15 wasn't installed so pivoted to iPhone 17 from then on), the Today view with DoseCardView and expand-on-tap, the multi-step Add Medication flow (eight step views + StepShell), local notifications with TOOK_IT / SNOOZE_10 actions and a MissedDoseChecker, and the History tab pillbox grid (7×4, ISO-8601 calendar with firstWeekday=2 for Monday-start, color-coded cells).

Three follow-up fixes the same evening:

Medication name was wrapping mid-word on iPhone 17 width because the time column and the "I took it" button both claimed fixed width. Relaxed layout priorities so the name column gets the leftover space with `.layoutPriority(1)`. Commit `798df5a`.

History tab got stuck — couldn't switch back to Today. First instinct was a stale committed source, but `git show HEAD` confirmed the source already had the implicit `TabView { }` form. Real cause: Claude Code had installed a `.constant(1)` debug build during screenshot capture, reverted the source, rebuilt, but never reinstalled the simulator. Sim was running yesterday's bytes. Fix was just a clean reinstall. No commit needed.

Notifications weren't firing because `requestPermissionIfNeeded()` only triggered on first medication save, and I hadn't walked the full Add Med flow yet — the test-notification debug button was scheduling silently against unauthorized state. Fixed by gating it through `handleTestTap()` that checks UNAuthorizationStatus first, requests permission on `.notDetermined`, surfaces an Open Settings alert on `.denied`. Added [NOTIF-DEBUG] logging with ISO-8601 fire timestamps and a `-DoselyAutoTest` launch arg for shell-driven verification. Commit `72f0bdf`.

Lessons: always reinstall after a source revert so sim state can't trail the commit. Silent permission failures hide the real bug — log OS state before scheduling against it.

Commits along the way: `9eccca6` (design system), `218c7ba` (Core Data + repo), `ce4266c` (Today), `42bae50` (Add Med flow), `09acdb8` (notifications), `ca8d96a` (History grid).

## April 23 — End-to-end notification verification

Built a second DEBUG pill, "Schedule real dose (2 min)", that creates a real Medication via the repository, attaches a DoseSchedule for now + 2 min, calls `scheduleReminders`, and dumps pending requests with [NOTIF-DEBUG]. Also added `.onReceive(UIApplication.willEnterForegroundNotification)` to TodayView so a dose logged via TOOK_IT on the lock screen surfaces in the UI immediately on foreground, not after the 5-minute poll.

Tested on a real iPhone: schedule a 2-min dose, lock the phone, banner fires at +2:00, tap "I took it" from the lock screen, open Dosely. Dose card already shows green dot and "Taken at HH:MM". Full pipeline end-to-end. Commit `da44a2d`.

## April 24 — Prompt 7: Firebase Auth

Email + password + Face ID. Two manual pauses Claude Code waited on (create the Firebase project at console.firebase.google.com, then drag GoogleService-Info.plist into the project at the right group level). Picked ObservableObject over @Observable to stay on iOS 16 — same semantics, smaller diff.

Smart calls Claude Code made: Keychain uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (right accessibility class for credentials that survive reboot but don't iCloud-migrate), Firebase error codes mapped to friendly strings via `AuthService.friendly(_:)` so wrongPassword / invalidCredential / emailAlreadyInUse / weakPassword / userNotFound / networkError / tooManyRequests don't reach the user as raw stack traces.

Forgot-password "email never arrived" was a Gmail spam-folder false alarm — Firebase's default `noreply@<project-id>.firebaseapp.com` sender gets flagged. Marked as not-junk once and future ones land in the inbox. If this keeps biting elderly users we'll set up a custom domain later.

Commit `af1ef30`.

## April 24 — Prompt 8: drug info + food guide

Static drug_info.json with eight common elderly meds (metformin, lisinopril, atorvastatin, amlodipine, levothyroxine, warfarin, low-dose aspirin, omeprazole). Each entry has whatItDoes / howToTake / common + serious side effects / a foodGuide with realistic entries (warfarin → leafy greens caution + alcohol avoid, atorvastatin → grapefruit avoid, levothyroxine → coffee/calcium/iron/soy avoid). Source row is DailyMed for everything, with deep-link search URLs.

`DrugInfoRepository.lookupCurated(for:)` is case-insensitive, whitespace-trimmed, with a longest-match fuzzy fallback so "Atorvastatin 20mg" / "Lipitor 40" / " Metformin " all resolve correctly. `MedicationDetailView` renders a clean card layout — bullet lists with green/amber/red dots in the food section, danger-tinted bullets for "call your doctor" side effects.

22/22 tests passing (11 from MedicationRepository + 11 new for DrugInfo). Commit `070c1ce`.

## April 24 — Prompt 9: openFDA dynamic info (F7)

Three-tier hybrid lookup so any medication grandma adds gets info without needing a JSON edit: Tier 1 = curated drug_info.json (fast, offline, grade-6 prose). Tier 2 = on-disk LRU cache of prior openFDA fetches (50-entry cap, fast, offline, survives relaunches). Tier 3 = live `https://api.fda.gov/drug/label.json` query on full miss. If everything misses, the friendly "ask your pharmacist" copy stays.

`lookupAny(for:) async throws -> DrugSource` is the orchestrator. Throws only when Tier 3 fails *and* there's no T1/T2 fallback, so offline-first is preserved for known meds. Cached entries get a "(cached)" suffix on the source label. Honest "From openFDA (clinical label)" badge for dynamic content + italic per-field caption "This is the official FDA label. Ask your pharmacist if any of this is unclear" — no pretending FDA prose is grade-6.

Commit `8bc2ef7`. 33/33 tests (11 repo + 11 curated tier-1 + 5 three-tier flow + 6 cache LRU).

Then a UX fix: dynamic content was rendering as walls of clinical prose instead of the bullet layout the curated meds get. Cause: drug_info.json provides arrays; openFDA returns flat strings. Built `OpenFDAContentParser` with a four-strategy waterfall — line bullets first (with the smart `*` / `-` requires-whitespace rule so "well-being" doesn't get split), then numbered lists via NSRegularExpression, then semicolons, then introducer-plus-comma (`include`, `such as`, `may include`, `are`, `consist of`) with a `nonItemPrefixes` filter that drops trailing clauses like "were reported." Sentence boundary detection respects 21 abbreviations (`Dr.`, `e.g.`, `etc.`, `vs.`). Both branches now route through the same `BulletRow` view — visual parity guaranteed by construction. 18 new parser tests on top of the 33.

Lesson: when one source returns prose and another returns arrays, parse to a common shape before rendering — don't fork the view.

## April 25 — Camera scan + Vision OCR

VNRecognizeTextRequest with the `.accurate` revision. AVFoundation camera with the proper permission gates (`.unconfigured`, `.denied`, `.failed`, `.authorized`). PrescriptionParser as a regex chain — name from the top-most alpha line (after filtering pharmacy banners like "pharmacy", "drugstore", "rx number"), dose with `\b(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|iu|units?)\b`, frequency mapping, food rule, quantity (explicit `Quantity:` label first, falls back to bare `<N> tablets` only when N≥2 digits and isn't preceded by `Take` so "Take 1 tablet" doesn't hijack the quantity).

The 17 parser tests caught three real bugs in one run: "twice daily" was matching as "Once daily" because the higher-arity patterns required the literal word "day" but `\bdaily\b` was on the once mapping (fixed: `(?:day|daily)` on twice/three/four), the name parser was picking pharmacy banners over the actual drug name (fixed: filter list), and "Take 1 tablet" was being read as quantity 1 (fixed: lookbehind for `Take`).

Surface: a "Scan a prescription label" button on AddMedicationFlow Step 1 above the manual TextField, dot-and-italic confidence indicators on the review screen — green check for ≥0.8, amber triangle for 0.5–0.8 ("Please double-check"), red octagon for <0.5 ("We couldn't read this — please type it in"). Low-confidence fields stay blank in `applyScanned` so the user types them — never put words in the doctor's mouth (B.1 S2). `INFOPLIST_KEY_NSCameraUsageDescription` baked into Debug + Release configs (Info.plist is autogenerated; without the key the app crashes on first camera access).

Simulator can't capture frames so the camera-permission gate path was the only one I could exercise from the shell. Real-iPhone scanning of an actual prescription bottle is the canonical test — pending.

## April 25 — Prompt 12 attempted: Punjabi localization (interrupted)

Started full Gurmukhi localization — Localizable.strings en + pa, drug_info_pa.json mirror, language picker on first launch, AVSpeech `pa-IN` voice helper. Caught a critical mismatch mid-prompt before any commit: my grandparents speak Punjabi but **don't read Gurmukhi**. The script most Indian-Punjabi Sikhs use is Gurmukhi; many Punjabi-speaking elders are literate only in English (or in Shahmukhi if they're from Pakistan), having migrated as adults.

Pressed Esc on Claude Code before the big refactor committed. The right path is probably audio-first — translate spoken output (notification voice readouts) to Punjabi while keeping the UI in English (or simplified English). Or possibly Hindi/Devanagari if that's what they actually read. Need to ask the family before re-running this prompt.

Critical research finding from the camera-scan run that's relevant whenever Punjabi gets re-attempted: Apple's Vision framework does NOT support Gurmukhi for OCR in any revision through iOS 18. Supported scripts are English, French, Italian, German, Spanish, Portuguese (PT-BR), Chinese, Cantonese, Japanese, Korean, Russian, Ukrainian, Arabic, Thai, Vietnamese, Swedish. Two fallbacks exist (Tesseract on-device, cloud OCR) but both break the offline-first rule. Recommendation logged: leave OCR English-only; pharmacy labels in BC are in English anyway.

Lesson, hard one: ask which **script** the user reads, not just which language they speak. Localization assumptions can waste a whole prompt's worth of work.

## April 25 — Face ID crash on real iPhone (commit `43fdbbb`)

App hard-crashed on the first tap of "Use Face ID" on the login screen. Smoking gun was `INFOPLIST_KEY_NSFaceIDUsageDescription` missing from both Debug and Release target configs — only the camera key had been added when the Auth prompt landed. iOS hard-kills the process on the first `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, …)` call when this key is absent — the kernel doesn't even let the completion handler fire. That's the real-iPhone crash exactly.

Two secondary tightenings while I was in there: `AuthService.biometricLogin()` was throwing silently (the LoginView catch swallowed errors without setting `errorMessage`), so every throw path now sets a localized AuthError description. Re-tagging do/catch ensures raw `LAError` enums never leak to the UI. Added `[AUTH-DEBUG]` logging at the start of `biometricLogin()` printing biometryType + canEvaluate + LAError code, with a static `describe(_:)` helper for human-readable type names.

Side-finding worth flagging separately: I'd renamed the bundle ID in Xcode from `com.placeholder.dosely` → `com.medication.dosely`. That means the Firebase iOS app needs its bundle ID updated to match (or `FirebaseApp.configure()` will silently fail to bind). Also `Keychain.swift`'s `kSecAttrService` is still hardcoded to the old name — opaque partition string, works as-is, but stale.

Lesson: every Info.plist usage description is a separate kernel-level gate. Adding NSCameraUsageDescription doesn't grant Face ID; each capability needs its own key.

## April 25 — Bug list from real-iPhone testing

Three more issues surfaced while testing on the actual phone, all queued for fixes:

Dark/light mode invisible text — DSColors uses single hex literals so tokens don't adapt. In Dark Mode the dark `dsTextPrimary` (#1A202C) shows on top of the system's near-black background and becomes unreadable. Fix queued: rewrite each token with `UIColor(dynamicProvider:)`, with dark variants chosen for ≥4.5:1 contrast (e.g., `dsPrimary` lifts #2B6CB0 → #4A90E2 because pure #2B6CB0 fails contrast on near-black). Plus a contrast-test suite using WCAG luminance.

Face ID setup prompt missing after sign-up — the alert from Prompt 7's spec ("Enable Face ID for quick access next time?") either was never wired or is silently gated. Queued.

Face ID always errors with "Your session has expired. Please sign in with your password" — this is the architectural one. Original Prompt 7 design assumed we could mint a new Firebase ID token from a stored refresh token after biometric success, but `Auth.auth().signOut()` wipes Firebase's own keychain entries, so post-logout there's nothing to unlock. The right pattern is 1Password/banking-style: split "Firebase signed-in" from "Dosely locally locked." Default Sign Out becomes "lock the app, keep Firebase session"; new "Sign out completely" wipes everything. Face ID success just flips the local lock — it doesn't touch Firebase. Queued.

Camera could use multi-photo or video capture for wrapped labels — pill bottles wrap text around the cylinder, single capture misses the back. Queued.

Lesson, third time in this project: error collapsing hides bugs. "Your session has expired" was hiding a fundamental design flaw. Distinct error codes everywhere from now on.

## April 25 — Prompt 13: Care circle data model

19 minutes. Brought in CareCircle and Person entities, moved every Medication and DoseLog under a Person, added PIN hashing with PBKDF2-SHA256.

Two things broke:
- Person.id nil-unwrap in CareCircleMigration. Fixed with `if let`.
- Default care circle name keys weren't in en.lproj or pa.lproj, so the migration test got back the raw key string. Added the keys and made the migration fall back to a default if NSLocalizedString returns the key unchanged.

101 tests passing. Auto-bootstrap keeps the app working through the transition.

Commit `f654663`.

## April 25 — Prompt 14: Supervisor dashboard

9 minutes. Built SupervisorDashboardView with three tabs (Today / History / People). PersonSelector with "All" combined view. Full PeopleManagementView with CRUD. AddPersonFlow with three branches: managed client, device client with PIN, supervisor invite. CircleSettingsSection. New repo methods: removePersonFromCircle (refuses to remove the last supervisor), updatePersonRole, renameCircle. HistoryView and AddMedicationFlow now scope to the active person via personIDOverride and supervisorTargetPersonID.

109 tests.

Three things flagged:
- Edit Medical ID button still points at a "Coming soon" alert. The editor isn't built.
- Dashboard UI not exercised on device yet. Data layer only.
- Punjabi translations are AI-drafted. Tracking in docs/translations_review.md.

Commit `8991b9c`.

## April 25 — Prompt 14.5: Circle setup audit and fix

Around 10 minutes. The audit caught a real bug before any code was written. CareCircleMigration.runIfNeeded had a third branch that unconditionally created a "My Family" circle for any new Firebase user. So sign-up auto-fabricated a circle and nobody ever saw the "join or create?" choice. The data tests all passed — the bug was in the flow, not the data.

Built CircleSetupView (welcome fork), CreateCircleView, JoinCircleView with six-digit boxes and paste support. Inline error banner for codeNotFound, alreadyMember, invalidName. Tightened the migration so it only auto-bootstraps for legacy orphans.

One real architectural call: keyed setup on Person existence rather than a UserDefaults flag. Survives reinstalls.

111 tests. Commit `5ed373f`.

## April 25 — Prompts 14.6/14.7: Join code normalization and leave-and-join

Two commits, same session.

**Commit `0158456` — join code fix.** Diagnostic logging found the bug before I touched the comparator. Case-sensitivity test failed — no-op for digit-only codes today, but a defensive gap. normalizeJoinCode now trims, strips interior whitespace, uppercase-folds. Core Data predicate uses `==[c]`. Three regression tests.

The cross-device bug was architectural, not the comparator. There's no Firestore yet. Care circles live in Core Data on one device. A code on Aunt 1's phone doesn't exist on Aunt 2's phone. Documented in CLAUDE.md.

**Commit `e8a8348` — leave-and-join.** Settings > Family for supervisors: name (read-only), join code with Copy + toast, Regenerate, Leave-and-join (destructive), Leave-permanently (destructive). Both leave paths block last-supervisor removal. LeaveAndJoinFlow is a fullScreenCover so AuthGate can't re-route mid-flow when currentPerson goes briefly stale. CareCircleRepository.leaveCircle returns Result with lastSupervisor / notMember / notFound.

118 tests.

## April 29 — Prompt 16: Firestore as source of truth

22 minutes. Wired Firestore as source of truth with Core Data as offline cache. New files: FirestoreModels (Codable mirrors), FirestoreService (transactional regenerateJoinCode, batched createCareCircle, listener helpers, error mapping, no-op fallback for unconfigured Firebase). SyncCoordinator owns listeners and does full reconciliation including orphan deletes. FirestoreUploadMigration is one-shot. joinCareCircle resolves through /joinCodes/{code} with Core Data fallback for offline.

Known limitations:
- No FCM push (free Apple Developer signing).
- 1-in-a-million join code race. Tolerated for MVP.
- DoseLogs orphaned by removePersonFromCircle aren't purged from Firestore yet.

Commit `d69bbda`.

## April 29 — Prompt 16 follow-up: compile errors

Build to iPhone failed with 4 errors — malformed `await context.perform` syntax from the refactor. Claude Code can't run a real build, only static analysis. Lesson: always run a clean xcodebuild after a big refactor.

## April 29 — Firestore cross-device sync verified

First test failed because Firestore production-mode rules denied every write. Opened rules to authenticated users (temporary), force-quit, migration uploaded data, second device joined. Silent-fail bugs (permission denial with no UI) are the worst kind.

## April 29 — Prompt 17: Firestore role-based security rules

29 minutes. Commit `9f5b4cd`. Full RBAC: /userMemberships/{firebaseUID} index, supervisorCount denormalized counter with getAfter for last-supervisor protection, deploy script, 20 emulator tests.

Mid-build, Claude Code caught an auth gap I missed: rules can't verify a joiner's authorization without seeing the joinCode they used. Added joinCode to membership docs (write-only at create, never read after).

## April 30 — Prompt 18: Primary/secondary supervisor split

Two commits, `aa8e2f6` and `53b614f`. Structural split: Roles.swift, PrimaryRoleMigration, atomic promoteToPrimary, Firestore rules with isPrimary / isAnySupervisor / isPromotionBatch, 38 emulator tests. Dashboard read-only UX: Primary / View-only badge, secondary notice replacing QuickActions, showActions plumbed through so secondaries don't see take/skip/snooze.

Real bug caught mid-prompt: repo tests were referencing FirestoreService.shared, which the host app configures at launch — test singleton pointed at production. Updated setUps to inject a no-op FirestoreService.

## April 30 — Test crash investigation (commit `04030fe`)

Crash report blamed testSecondaryCanLeaveWhenPrimaryRemains line 295, but that line is just repo.createCareCircle — boilerplate. The leave path uses try? and has no force-unwraps.

Real cause: FirestoreService.useEmulator() reassigned db.settings on the process-wide Firestore SDK singleton every setUp. SDK locks settings after first operation. Second test threw FIRIllegalStateException. The Objective-C exception propagated through Swift's continuation queues and the test runner blamed whichever test was next in the queue.

Compounding it: CareCircleMigration.runIfNeeded built repos against FirestoreService.shared. Migration tests froze settings before FirestoreServiceTests could configure them.

Fix: useEmulator() is now idempotent. runIfNeeded accepts an injectable firestore: parameter.

141 tests, 0 failures.

Lesson: a Swift crash report's "faulting test" can be wrong when an Obj-C exception propagates through async/await. Look for shared singleton mutation in setUp before blaming the named test.

## April 30 — Production rules deploy broke read access

Deployed Prompt 18 rules. Every read and write returned "Missing or insufficient permissions." Reverted to permissive rules while diagnosing.

Root cause:
1. Rules require /userMemberships/{auth.uid} to exist for every careCircle read.
2. 38 tests all seeded the membership doc. Never tested "legacy supervisor + missing membership."
3. Aunt 1 had a Person row and CareCircle but no membership doc.
4. Membership-create rule had three branches but none let an existing supervisor self-create. Chicken and egg.

Fix: new "self-backfill" branch (d). Person doc is the authoritative source. Migration split into two phases — Phase A backfills membership via setData(merge: true), Phase B is the existing atomic batch. Two-phase required because one-shot would let a secondary self-promote (verified by a new defense-in-depth test).

51 rules tests (+13 new), 141 Swift tests.

Lesson: rules tests that pass on the emulator can fail in production because real data has shapes the test setup doesn't simulate.

## April 30 — "iPhone can't read care circle" was wrong account

Simulator worked, iPhone didn't. Spent time assuming another rules bug. Real issue: the iPhone was signed into a different Firebase account with no membership. Rules were correctly denying access.

Lesson: when one device works and another doesn't on the same code and Firestore, check auth.uid first.

## April 30 — CircleSetupView fix (commit `9835c11`)

AuthService.resolveCurrentPerson deferred to CareCircleMigration, which only consulted Core Data. On a device with empty cache, it returned nil despite everything existing in Firestore. needsCircleSetup flipped true.

Fix: new RemotePersonResolver queries /userMemberships/{firebaseUID} first, hydrates CareCircle and Person into Core Data. Returns .found / .notFound / .unavailable. AuthService calls the resolver first; only on .notFound or .unavailable does it fall through.

Lesson: "is this user new?" is a question about Firestore, not the local cache. Caches lie.

## April 30 — Phantom join code bug (commits `c3018c2`, `841e4b7`)

Tapping "Regenerate join code" produced a code that existed nowhere in Firestore. Three docs in /joinCodes/ pointed at three different careCircles (orphans), but the UI showed a 4th code not in any of them.

Three silent-failure paths stacked:
1. runTransaction with no reads — degenerate shape, rejected without throwing visibly.
2. guard let db else { return } silently no-op'd.
3. Repo collapsed every error to .offline, which the UI ignored.

Fix: WriteBatch instead of runTransaction. db == nil throws .offline. .permissionDenied preserved distinct. UI shows "Couldn't regenerate code" instead of swallowing. Core Data only updates after Firestore confirms. Plus orphan cleanup migration.

Lesson: layered silent failures are the worst bug class. Each layer was "graceful" alone. Together they produced a fabricated value. Optimistic UI should never apply to data shared with another device.

## April 30 — Manual deletion of orphan circles

Cleanup migration didn't fire for legacy circles missing primarySupervisorPersonID. Deleted the 2 orphans manually in Firebase Console instead of shipping another fix. They were debugging artifacts, not real data.

Lesson: not every bug needs a code fix.

## April 30 — Cross-device join finally fixed (commit `1f6455c`)

lookupJoinCode was fetching /joinCodes/{code} (allowed) then reading /careCircles/{id} (denied — joiner isn't a member yet). The "listener failed" error was actually a getDocument permission failure. joinCareCircle's catch-all collapsed it to .codeNotFound.

Fix: lookupJoinCode returns only careCircleID now. New joinCircleAsSecondary writes userMembership, Person, and supervisorCount in a single WriteBatch. Rules use existsAfter for post-batch validation.

Errors no longer collapse: .permissionDenied, .codeNotFound, .alreadyMember, .offline, .unknown each get a distinct message.

Lesson, third time: error collapsing hides bugs. Same problem on regenerateJoinCode and joinCareCircle. Distinct error codes everywhere from now on.

## April 30 — First successful cross-device join

Aunt 1 on simulator (primary). Aunt 2 on iPhone (different Firebase account, joined via code). Same care circle. Role-based access enforced. Cross-device sync via Firestore listeners.

Total bugs debugged today: rules locked out legacy users, sign-in only checked local cache, regenerateJoinCode silently failed (three stacked), join flow attached listener before writing membership, error mapping collapsed permission-denied into codeNotFound. Each fix shipped with a regression test.

Hardest architectural piece is done. What's left is more linear.

## May 1 — Pull-to-refresh on Today, History, People (commit `880313e`)

The app's been listener-driven for fresh data since Prompt 16. When a listener drops — network blip, backgrounding, anything — the user has no recovery short of force-quitting. Native pull-to-refresh fills that gap: an obvious gesture that runs the same per-collection reads as the listener pipeline, but as a one-shot round trip.

`SyncCoordinator.refresh()` is the new entry point. Concurrent `async let` fetches over careCircle, people, medications, schedules, and dose logs, then the existing private mirror helpers upsert into Core Data and prune locally-orphaned rows. Aborts on the first failure rather than mirror a partial snapshot — mistaking "couldn't ask" for "the server has empty data" would let the orphan-pruning helpers wipe the local cache. Errors land as `SyncRefreshError` (offline / permissionDenied / unknown) so the UI maps each to distinct copy.

That cache-wipe-on-empty trap also hid in `FirestoreService.fetchPeople`, which used to return `[]` when the SDK wasn't configured. Hardened to throw `.offline` instead, alongside three new fetchers — `fetchMedications`, `fetchDoseSchedules`, `fetchDoseLogs` — that follow the same contract.

UI glue lives in `Dosely/Features/Common/PullToRefresh.swift`: a `PullToRefresh.perform(messageBinding:)` helper runs the refresh and writes any error's localized copy to a binding, plus a `pullToRefreshBanner` view modifier that renders an inline banner and auto-dismisses it after ~3s. `TodayView`, `HistoryView`, `PeopleManagementView`, and `SupervisorDashboardView`'s todayTab all wrap their content in a ScrollView with `.refreshable` and the banner modifier. Pull-to-refresh works for primary and secondary supervisors equally — the gating already lives in `SyncCoordinator`, which respects circle membership regardless of role.

Two `TodayView` shape changes worth noting. The outer container is now a single ScrollView; the date header used to live in a VStack outside the content's conditional inner ScrollView, which meant pulling from the header didn't trigger refresh. And the populated state's inner ScrollView became a plain `LazyVStack` so the gesture isn't fighting a nested scroll view.

Tests in `DoselyTests/PullToRefreshTests.swift`: silent no-op when there's no active circle, `.offline` against an unconfigured `FirestoreService`, mirrors fresh data into Core Data against the local emulator. Three smoke tests host each tab in a `UIHostingController` and assert a `UIScrollView` is present in the rendered hierarchy. SwiftUI's `.refreshable` attaches its `UIRefreshControl` to the underlying scroll view; without it the gesture has nowhere to live, and a refactor that wraps content in a VStack instead would silently break it.

The trap I keep hitting on this codebase: a function that "gracefully" returns an empty result when something's wrong reads identically to a function that says "yes, the answer is empty." Combine that with downstream code that prunes anything not in the result and you have a cache-wipe machine. Better to throw and let the caller decide.

## May 1 — Add-person chooser was rendering raw localization keys (commit `7541904`)

People → "+" → "Add a family member" was showing `supervisor.add.managed.title` etc as the option titles. The user's first guess was missing keys; the keys were actually present in both `en.lproj` and `pa.lproj`. Bug was at the call site in `Dosely/Features/Supervisor/People/AddPersonFlow.swift`:

    Text(type.titleKey)   // type.titleKey is a runtime String

`Text(_:)` on a runtime `String` binds to the verbatim initializer and skips Localizable.strings. Only `Text(LocalizedStringKey)` — which Swift picks for string literals — routes through the bundle. Same trap was sitting on the `.fillForm` nav-title branch, latent until anyone made it to step 2 of the flow. Fix was three `L(...)` wrappers.

Two tests in `DoselyTests/AddPersonFlowLocalizationTests.swift`. The first probes the lookup table — every chooser key must resolve to something other than itself in `en.lproj` — which catches the user's original hypothesis if a future chooser type ships without strings. The second renders the chooser in a `UIHostingController` and walks the UIKit hierarchy for any `UILabel.text` that equals one of the six raw keys. That one catches the actual bug class (key resolves but the call site never asked for localization), which the lookup test alone would miss.

The diagnosis matters more than the fix. The user's hypothesis was specific and confident, and a few of the suggested replacement strings drifted away from what the data model actually supports — "Someone with their own iPhone" for `device_client` reads like the device client owns the phone, but in this app device clients share the supervisor's phone with a PIN. Reading the source first beat patching to the brief.

## May 1 — Managed client double-rendered on the People list (commit `b505044`)

Add a managed client through People → "+" → "Someone I care for", and the new row appeared twice. One Firestore doc, two Core Data rows holding the same UUID. Confirmed by the user: deleting either row deleted the other, which is the fingerprint of the orphan-prune sweep doing its job after both rows lost their Firestore parent at once.

The shape of the bug, in `Dosely/Data/PersonRepository.swift`:

    try? await firestore.upsertPerson(fperson)
    return await context.perform { ... in
        let person = Person(context: context)   // always-insert
        ...
    }

The Firestore write fires the `/people` listener on this device. `SyncCoordinator.mirrorPeople` runs on a fresh background context, calls `FPerson.upsert`, finds nothing at this UUID, and inserts. Then the view-context block above runs and inserts ANOTHER row at the same UUID. The Person entity has no uniqueness constraint at the data-model layer (and Core Data doesn't enforce one without an explicit `<uniquenessConstraints>`), so both rows happily coexist. The People list iterated `[Person]` directly and rendered both.

Fix is the FPerson.upsert pattern lifted into both create paths: fetch by id, reuse the existing row if present, otherwise insert. Same change to `createDeviceClient`. Added an optional `personID:` parameter (defaulted to `UUID()`) so the regression tests can pre-seed a row at a known id and prove the upsert.

Tests in `DoselyTests/PersonRepositoryTests.swift`: exactly-one-row from a clean create for both paths, plus an upsert-against-pre-seeded-row test for each that drops a Person at a known id, calls the repo, and asserts the row count stays at one with the new fields applied. The pre-seeded row stands in for the listener-already-mirrored race that the no-op FirestoreService in this test suite otherwise prevents.

The hazard is "create" methods that act like inserts when the rest of the layer treats Firestore as the source of truth. Once Firestore is the canonical store, every local write should be an upsert keyed on the canonical id — not a fresh insert and a hope that nothing else got there first. Worth scanning the rest of the repos for the same pattern next quiet hour.

## May 1 — Dashboard selector listed co-supervisors as patients (commit `41f93cd`)

The person-selector strip on the Today tab and the "All" combined-doses path both read `SupervisorDashboardViewModel.clients`. The filter, in `Dosely/Features/Supervisor/SupervisorDashboardViewModel.swift`, was:

    .filter { $0.id != supervisorID }

That excluded only the acting supervisor's row, not every supervisor in the circle. With two caregivers in the same family, the second one rendered next to Grandpa as if they were a patient — tappable, with their own (empty) doses screen.

Fix is a role filter. Per the data model in `CLAUDE.md`, both `device_client` and `managed_client` are dose-targets; every supervisor flavor (primary, secondary, legacy) is a caregiver. Filter is now `$0.role == Roles.deviceClient || $0.role == Roles.managedClient`.

Tests in `DoselyTests/SupervisorDashboardViewModelTests.swift`: two managed clients plus a co-supervisor reduces to two clients in the array; a secondary supervisor loading the dashboard gets the same client-only list (the previous filter would have leaked the primary in for them); and the "All" combined-doses path only ever surfaces medications belonging to the filtered clients.

Same shape of mistake as the chooser fix three commits back — a filter that almost did the right thing but landed on the wrong key. The previous one filtered on object identity instead of role; this one filtered on a single id instead of a role class. The data layer has roles; the views should ask in those terms, not by exclusion of whoever happens to be running the screen.

## Still pending

- Dark/light mode adaptive DSColors (queued — invisible text on real iPhone)
- Face ID setup prompt after sign-up (queued — alert never appears)
- Face ID session-expired redesign — local-lock pattern (queued — biggest of the three Face ID issues)
- Multi-photo / video capture for wrapped labels (queued — pill bottles wrap text around the cylinder)
- Bundle ID alignment — update Firebase iOS app to `com.medication.dosely`, optionally retire the old `kSecAttrService` string in Keychain.swift
- Prompt 18 manual test plan (steps a-g): primary/secondary badges, hidden affordances, alert acknowledgement, promote-to-primary swap
- Edit Medical ID screen (still "Coming soon")
- Prompt 19: real-time alerts (missed dose, emergency, weekly summary)
- Punjabi re-attempt — confirm with the family which **script** they actually read before re-running Prompt 12 (grandparents don't read Gurmukhi); audio-first may be the right shape
- Accessibility toggles polish (Prompt 10 was skipped — text-size override, high-contrast mode, voice readout helper)
- Emergency Medical ID screen (Prompt 11 was skipped — lock-screen-accessible read-only ID for paramedics)
- Real-iPhone scan test with an actual prescription bottle (simulator can't capture frames)
- Round 2 client testing — structured, with stopwatch and silent observation
- Portfolio cleanup: empty A.2 prioritization body, A.3, B.1, B.4 wireframes, leftover duplicate A.1 page

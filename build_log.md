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

## May 1 — Stubbed Refill alert removed (commit `5d1c678`)

The Today tab's AlertsCard was showing "Refill check — Watch %@'s pill supply this week" any time a client was selected, regardless of supply state. The function in `Dosely/Features/Supervisor/SupervisorDashboardViewModel.swift` was named `stubAlerts` and the doc comment promised "replaced in Prompt 15" — placeholder content that never got replaced. The user reported it substituting "Grandpa" while a different person was visibly selected, which I'd guess is stale `activePersonID` state from the duplicate-row bug we shipped earlier today, but the symptom is moot once the stub is gone.

Supply tracking has a `currentSupply` field on Medication but no threshold-driven alert path. Real alerts — missed-dose rollups, low supply, PIN lockout, emergency button — are queued for Prompt 19. Until then, `viewModel.alerts` is `[]` and the AlertsCard renders its existing "supervisor.alerts.empty" copy. The two unused localization keys came out of `en.lproj` and `pa.lproj` while I was in there.

Two new tests in `DoselyTests/SupervisorDashboardViewModelTests.swift` assert the alerts array is empty both for the single-client view (zero medications) and the All view. Previously either path would have surfaced the stub.

Worth tagging: stubs that ship with `Prompt N` markers in the comments and never get replaced are a recurring source of these reports. The doc comment above `stubAlerts` literally said "replaced in Prompt 15" and we're past 19 by the rest of the codebase. A periodic grep for "stub" or "Prompt N — replace" might be worth a /schedule.

## May 4 — Supervisor alert system, end to end (commits `7faca6c`, `71f7746`, `eedbdbc`)

The coordination model the project's been promising: every supervisor sees the same alert, first to acknowledge clears it for everyone. Three commits, each leaving the codebase in a working state so I had a clean cut point if scope blew up.

`7faca6c` is the foundation. New Core Data `Alert` entity with type/personID/medicationID/scheduledTime/createdAt/payloadJSON/acknowledgedByFirebaseUID/acknowledgedByName/acknowledgedAt and a relationship from `CareCircle`. The placeholder `FAlert` shape from Prompt-14 (kind/message/resolvedAt) got rewritten to match — `type`/`payload`/`acknowledgedBy` etc. The `AlertID` helper mints deterministic doc ids: `missed-{personID}-{medicationID}-{epochMillis}` for missed-dose alerts and `weekly-{circleID}-{ISODate}` for weekly summaries. Concurrent supervisor devices detecting the same gap converge on a single doc; only the first write commits and the rest get a benign "already exists" back. `FirestoreService` gains `fetchAlerts`, `createAlertIfAbsent` (with a get-then-write prelude that softens the SDK's already-exists bark into a quiet false return), and `acknowledgeAlert` (a transaction that aborts silently when someone else won the race). `AlertsRepository` does synchronous Core Data reads sorted pending-first / acknowledged-second, both newest-first within. `SyncCoordinator` got a new `/alerts` listener and the refresh path picks them up alongside everything else.

The rules tightening landed in the same commit. `/alerts/{alertID}` now requires `isAnySupervisor` for read (was member); create requires the supervisor + `createdAt == request.time` + `acknowledgedBy` null; update is the four-key allowlist (`acknowledgedBy`, `acknowledgedByName`, `acknowledgedAt`, `lastModified`) with the existing-ack-must-be-null and new-ack-must-equal-auth-uid constraints; delete is orphan-cleanup-only (the spec said `false`, but the existing migration still needs to tear down a circle's alerts). The previous looser rules were overwritten and the rules tests rewritten — 10 cases covering supervisor/stranger reads, fresh creates, pre-acked-create denial, time-skew denial, self-ack, third-party-ack denial, overwrite denial, non-ack-field denial, delete denial.

`71f7746` is the generators. `MissedDoseDetector` walks every dose-target in the circle, pulls today's scheduled doses + dose logs in two queries per person, and for each scheduled dose past `now - graceWindow` with no matching log, mints the deterministic alert. Default grace is 30 minutes — it's the buffer for someone who's mid-tap. `WeeklySummaryGenerator` returns nil for any non-Sunday and any Sunday before 6pm; on Sunday at-or-after 6pm it computes per-person `taken/scheduled` from the past seven days of `DoseLog` rows and writes the `weekly-{circleID}-{ISODate}` alert with a `name|taken|scheduled` payload row per person plus a `_summary` total. Five tests for the detector (gap, grace, log-already-exists, two-slot distinct ids, idempotency) and four for the generator (window math, nil-on-non-Sunday, deterministic id, encodeStats + percent rounding including 0/0 = 100). Plus three for `AlertsRepository` covering the sort, the pending filter, and the optimistic-local-ack semantics on offline.

`eedbdbc` is the UI. `AlertsCard` rewritten to render real `Alert` rows with type-aware icons (`clock.fill` / `exclamationmark.triangle.fill` / `chart.bar.fill`), body strings keyed off the payload map, and either an Acknowledge button or an "Acknowledged by …" status. The dashboard's `acknowledge` callback hits the atomic transaction via the repository, then reloads — the listener will reconcile any drift. `SupervisorDashboardViewModel.load` now runs the detectors before reading the inbox, and the dashboard hooks `willEnterForegroundNotification` so detectors re-fire when the supervisor returns to the app. `TodayView` gains a single big red "I need help" button gated on `role == .deviceClient` — tap presents a confirmation, confirm writes a fresh emergency alert with a UUID id (no idempotency for emergencies; every tap is its own incident), then a 3s "Alert sent" toast. The smoke test in `DoselyTests/AlertsCardSmokeTests.swift` hosts the card with a pending missedDose row and an acked emergency row in a `UIHostingController` and asserts the rendered hierarchy carries the person name, medication name, acknowledger name, and the Acknowledge button — catches refactors that drop the type switch.

Known limitations:
- No push. A missed-dose alert only fires when at least one supervisor has the app foreground or returns it from background. The 5-minute internal cadence in `TodayView` doesn't extend to the supervisor dashboard yet — foreground + pull-to-refresh + initial-load are the live signals.
- Worst-case latency is therefore "until the next foreground." Tighten with a 5-minute timer on the dashboard if the practical cadence in testing isn't acceptable.
- Emergency assumes the device is unlocked and Dosely is open. A real emergency system needs lock-screen or hardware integration; out of scope.

The lesson worth keeping: deterministic doc ids are how you turn N concurrent generators into one source of truth. Every supervisor's device runs the same detector independently and they all aim at the same Firestore doc — the rules-layer create gate plus the get-then-write prelude in `createAlertIfAbsent` ensures only the first lands. No coordination protocol, no leader election, no "elected detector" complexity. The id IS the agreement.

## May 11 — Edit Medical ID, end to end (commits `43a0b29`, `b2c1e87`)

Replaced the Edit Medical ID quick action's "Coming soon" alert with an actual editor. Two commits: foundation first, UI second, both standing alone in case scope went sideways.

`43a0b29` is the data layer. New Core Data `MedicalID` entity with personID/dateOfBirth/bloodType/notes/updatedAt + three JSON-encoded list fields for allergies, conditions, and emergency contacts, with a 1-to-1 inverse to Person carrying a Cascade delete rule. The list fields live in JSON strings because medical info is never queried in pieces — it's read whole, written whole, displayed whole. Three more Core Data entity types would have been overkill for free-text rows that nobody filters. The Firestore path is `/careCircles/{circleID}/people/{personID}/medicalID/{personID}` — nested under each person, doc id equals personID for deterministic addressing. `FMedicalProfile` (the Prompt-14 placeholder) stays around so legacy docs can still decode on devices upgrading from earlier builds; nothing post-prompt-20 writes that path.

`MedicalIDRepository.save` uses the Firestore-first pattern the regenerate-join-code prompt established: remote commit runs first, only on success does the Core Data mirror update. A failure leaves the prior state intact. The earlier "phantom join code" bug burned the lesson in — emergency responders look at this screen, we can't ever let the local cache show a value that didn't land server-side.

Rules at `/careCircles/{circleID}/people/{personID}/medicalID/{medicalDocID}`: read by any supervisor (egalitarian — primary or secondary, paramedics care about freshness more than authorship); create/update by any supervisor with `medicalDocID == personID`, payload `id == personID`, payload `personID == personID`, and `updatedAt == request.time`; delete is the cascade-from-Person-removal hatch only. The cascade rule uses `!exists(parent)` to encode the ordering: `PersonRepository.removePersonFromCircle` deletes the Person doc first, then this doc, so by the time the medical-id delete fires the parent is gone and the rule lets it through. The orphan-founder branch handles `OrphanCircleCleanupMigration`'s tear-down regardless of order.

Tests in `tests/firestore_rules.test.ts`: eight cases for the medical-id path — supervisor create allowed, stranger read denied, supervisor read allowed, doc-id-mismatch denied, time-skew denied, supervisor update allowed, steady-state delete denied (parent alive), cascade delete after parent removal permitted. Plus repository tests in `DoselyTests/MedicalIDRepositoryTests.swift` covering fetchLocal returns, the Firestore-first save semantics under offline (`.offline` thrown AND local cache untouched), the JSON encode/decode round-trip preserving every list shape, and the cascade-delete from `PersonRepository.removePersonFromCircle` clearing the local MedicalID row.

`b2c1e87` is the editor. `Dosely/Features/Supervisor/MedicalID/EditMedicalIDView.swift` has five sections — Basics (date of birth + blood type), Allergies, Conditions, Emergency Contacts, Notes — with the "+ Add" / "-" pattern for the three list-shaped fields. Save runs the repository's Firestore-first path. The in-flow target picker reuses `AddMedicationTargetPicker` with a new optional `titleKey:` parameter so it reads "Edit Medical ID for whom?" in this context. The dashboard's quick action always opens the editor; the in-flow picker handles "All" cases — same single failure mode as `AddMedicationFlow`. `PersonDetailView` gains a Medical ID section below the existing Medications section, only on non-supervisor people.

Smoke tests in `DoselyTests/EditMedicalIDViewTests.swift` exercise the same shape as the AddMedicationFlow tests: a pure-decision helper for the picker-vs-form branching, plus two UIHostingController renders that walk the rendered hierarchy for the expected text in each arm. The `// REVIEW NEEDED` Punjabi keys went in alongside the English — 26 new keys total, verified each one has a matching en entry before committing.

The trap I keep dodging: making delete `false` everywhere reads safer than it is. Both the alerts work last week and this prompt nearly got blocked on it. The right shape is "delete denied in the steady state, permitted under a precisely encoded condition" — for alerts the condition is the orphan-founder cleanup; for medical IDs it's `!exists(parent)`. Rules can express the lifecycle invariant exactly when you let them.

## May 13 — Medical ID save permission denied; encoded the error-collapse convention project-wide (commit `acd03c6`)

Save from EditMedicalIDView came back permission-denied and the UI rendered "Couldn't save. Check your connection and try again." Wrong copy — it's a rules rejection, not a network issue. Same error-collapse pattern that hit regenerateJoinCode in `c3018c2` and joinCareCircle in `1f6455c`. Fourth time. Time to stop patching one repository at a time and write the convention down.

The actual save failure came from the Codable-encode-then-override pattern in `upsertMedicalID`: `try encode(medicalID)` emits the FMedicalID with `updatedAt: Date(client)` as a Firestore Timestamp, then `payload["updatedAt"] = FieldValue.serverTimestamp()` overwrites it. Most SDK versions handle the override correctly, but the wire shape was a black box and the rule's `request.resource.data.updatedAt == request.time` check is unforgiving. Rewrote the payload as explicit dict construction with optional fields conditionally included. Same shape the rules tests have always verified; no more transient state between encode and ship.

But the real work is the convention. `FirestoreServiceError` already had four distinct cases — `.permissionDenied`, `.offline`, `.notFound`, `.unknown(String)`. The collapse was happening UPSTREAM, in repository catch chains that dropped the four cases into one or two domain-error buckets, and in UI catch sites that used a single generic "couldn't save" message regardless. The fix isn't bigger error types; it's the discipline to translate one-to-one all the way to the user-visible string.

Concrete changes:
- `MedicalIDRepositoryError` enum with the four-case shape mirroring `FirestoreServiceError`. `MedicalIDRepository.save` now `catch`es each FirestoreServiceError case and rethrows the matching domain case. No more `catch { throw .offline }`.
- `CareCircleEditError` gains `.unknown(String)`; regenerateJoinCode's previous "any other error → .offline" line — the very pattern this convention is meant to prevent — is gone. The detail string flows to `Logger` for post-hoc diagnosis.
- `EditMedicalIDView.save` branches on the four cases and shows distinct copy. "This action was denied. Sign out and back in if you think you should have access." reads very differently from "Check your connection."
- `FirestoreServiceError.map` writes every unmapped error to `Logger(subsystem: "com.medication.dosely", category: "firestore")` so a future investigation can use Console.app instead of attaching Xcode.
- Every catch site that maps Firestore errors carries `// Distinct error codes per error-collapse convention — see build_log April 30 phantom join code entry.` Grep-friendly for the next reviewer.
- `CLAUDE.md` gains an "Error-collapse convention" section under Coding conventions. Future Claude sessions inherit the rule via the loaded context — the cheapest possible enforcement.

Tests in `DoselyTests/ErrorCollapseConventionTests.swift` are type-level guards: `FirestoreServiceError.map` distinctly maps the three Firestore codes, `.unknown` carries the diagnostic detail string, non-Firestore domain errors don't collapse to `.offline`, and each repository's domain error enum carries distinct `.permissionDenied` vs `.offline` cases. A "let's simplify the error type" PR would fail at compile time first and these tests second.

Pattern-level note: shipping the same bug four times means the convention is missing, not that an engineer keeps making the same mistake. Patching one repo at a time is treating the symptom. Putting the rule in CLAUDE.md so it gets loaded into every future context, comment-marking every catch site so the rule travels with the code, and type-level tests so a future refactor fails loudly — all three, because any one of them on its own would have failed at least once already.

## May 14
- Testing Git Commits

## May 27 — Medical ID save still failed; root cause was an undeployed rules file

Picked up the test plan on the iPhone and the simulator side by side, expecting Edit Medical ID to save cleanly after `acd03c6`. It didn't. EditMedicalIDView surfaced "This action was denied. Sign out and back in if you think you should have access." — which is the correct copy now that the error-collapse work is in, and it pointed me at the right shape of problem on the first try. Firestore listener for `careCircles/{id}/people/{id}/medicalID/{id}` was failing reads too, not just the write — three separate "Missing or insufficient permissions" denial events in Console.app under `com.medication.dosely`, two on initial fetch, one on the save itself.

PROJECT_HANDOFF section 17 listed three hypotheses. Walked them in order. The repo's `firestore.rules` had the medical-ID create/update predicate, the doc-id-equals-personID check, the `request.time` clamp — all the right shape. The emulator tests in `tests/firestore_rules.test.ts` passed. The Swift payload in `FirestoreService.upsertMedicalID` matched the rule's expectations. So if both halves looked right and the live project was rejecting, the only thing left was the live project running a different ruleset than the file in the repo.

Opened the Firebase Console rules page. The "Published" timestamp on the live ruleset was from April 30 — three weeks before the medical-ID work landed. The rules file on disk was current; the deploy had never run. `firebase deploy --only firestore:rules` from the repo root, watched the Published timestamp jump to "a few seconds ago," reran the save flow. Wrote cleanly. Both listeners reconciled, the in-progress edit landed, the EditMedicalIDView dismissed. No code change.

Worth dwelling on `acd03c6` for a moment, because it would be easy to mark it as "fix that wasn't actually the fix" and move on. Two reasons it was still worth shipping: the `updatedAt` rewrite removed a real footgun. `Firestore.Encoder().encode(...)` emitted the FMedicalID with `updatedAt: Date(client)` as a Firestore Timestamp, then `payload["updatedAt"] = FieldValue.serverTimestamp()` overwrote it before the call. Most SDK versions handle the override correctly, but the wire shape was a black box during the override window, and the rule's `request.resource.data.updatedAt == request.time` check is unforgiving. The explicit-dict construction in the new `upsertMedicalID` is what the rules tests have always verified. Second reason: the error-collapse encoding earned its keep today. The previous code path would have surfaced "Couldn't save. Check your connection and try again." — the exact wrong copy for a rules rejection — and I'd have spent the morning chasing Wi-Fi instead of opening the Firebase Console. The fourth-time-burned pattern from `c3018c2` / `1f6455c` / `acd03c6` was the right thing to encode project-wide; this morning is the test case that proves it.

The bit that's worth marking down, even without an action attached: rules tests passing on the emulator does not imply the live project is correct. The April 30 phantom join code work shipped under the same shape — rules tests green, production rejected because the deploy hadn't run. Now medical-ID under the same shape, eight weeks later. Two for two. The lesson isn't "the rules are flaky" — they're fine. It's that deployment is a separate step from passing the test suite, and there's currently no automation that confirms the live ruleset's hash matches the committed file. A pre-commit or pre-push hook that diffs `firebase deploy --only firestore:rules --dry-run` against the production hash would catch this class of failure at the moment it's introducible, not the next time someone runs the manual test plan. Holding off on writing that convention into `CLAUDE.md` — Josh has explicitly deferred it — but flagging it here so the next time it bites, the prior art is two entries old, not buried.

## May 27 — Prompt 18 e/f/g: audited, tested, instrumented, playbook written

The three remaining items from the Prompt 18 manual test plan are alert acknowledgement (any supervisor's tap clears the row on every other device), promote-to-primary (a primary hands the role to a secondary, both flips land atomically), and role transition during an active alert (the ack still works even if the transition is mid-flight). Couldn't run them myself — they need two physical devices side by side — so the shape of the work is: audit the code paths, expand automated coverage so the manual run becomes confirmation rather than discovery, instrument the transition points so Console.app reads as a diagnostic narrative, then write the playbook Josh follows.

The audit turned up one real reactivity gap and one error-collapse violation. `SupervisorDashboardView.isPrimary` was a computed property that read `authService.currentPerson?.careCircle?.primarySupervisorPersonID` — the @EnvironmentObject pattern only invalidates the SwiftUI view when the @Published property is reassigned, not when nested NSManagedObject fields mutate underneath it. A listener-driven demote on a foreground Today tab would have flipped Aunt 1's `Person.role` in Core Data, left the dashboard rendering as if she was still primary until a tab change or foreground forced a re-evaluation. The fix is a `@Published var actorIsPrimary: Bool` on `SupervisorDashboardViewModel`, driven by a `NSManagedObjectContextObjectsDidChange` observer on the view context. `automaticallyMergesChangesFromParent = true` on the view context means background-context saves from the listener path post that notification too, so one observer covers both local and remote mutations. The view now reads `viewModel.actorIsPrimary`; the badge, QuickActionsCard, and read-only notice all move with the underlying state.

The error-collapse violation was in `PersonDetailView.makePrimary` — the catch chain branched on two `PersonRepositoryError` cases distinctly and lumped every other `PersonRepositoryError` AND every `FirestoreServiceError` into a single "generic" string. The rules-rejection path (`FirestoreServiceError.permissionDenied`) would have read as "We couldn't complete that. Please try again." — same shape that hit `MedicalIDRepository.save` two weeks ago. Rewrote `mapError` to branch on `FirestoreServiceError` cases explicitly with distinct copy ("Couldn't reach the server" for `.offline`, "Couldn't find that record" for `.notFound`, "Only the primary supervisor can do that" for `.permissionDenied`), pulled `makePrimary` to route through it, added the grep marker comment, and added `supervisor.person.error.offline` / `supervisor.person.error.notfound` to `en.lproj/Localizable.strings` + the `// REVIEW NEEDED` Punjabi drafts.

Everything else in the audit was already correct. `FirestoreService.acknowledgeAlert` is a proper read-then-write transaction (not the degenerate pure-write shape that gave us the phantom join code bug); `AlertsRepository.acknowledge` lets `FirestoreServiceError` propagate untouched so callers branch on the four-case taxonomy directly; `AlertsCard`'s Acknowledge button visibility depends only on `acknowledgedByFirebaseUID`, NOT on actor role, which means a freshly-demoted ex-primary still sees the button (correct under the rules layer, where `isAnySupervisor` allows acks from either flavour). `FirestoreService.applyPrimaryAssignment` writes all five docs in one batch and `firestore.rules`'s `isPromotionBatch` helper recognizes that exact shape. I added grep-marker comments to the catch sites in `acknowledgeAlert` and `applyPrimaryAssignment` too — they map Firestore errors and the convention's enforced by comment presence.

For automated coverage: seven new rules tests in `tests/firestore_rules.test.ts` covering first-write-wins-on-ack from a different supervisor (e1), the legacy `"supervisor"` role being able to ack (e2), device clients being denied (e3), the `updateData` against a missing target membership refusing to commit (f1), peer-to-peer secondary promotion refused (f2), cross-circle target refused (f3), and a single batch that combines a promotion AND an unrelated ack committing successfully (g1 — pinning that the rules-layer treats each write independently, which a future "tighten this to single-purpose batches" PR would break). Rules suite went from 76 passing → 83 passing; all 7 new tests green on first run.

On the Swift side, three new tests: `testPromoteToPrimaryRefusesTargetInDifferentCircle` and `testPromoteToPrimary_errorCasesAreDistinct` in `PersonRepositoryTests.swift` (the latter is the type-level guard that `.notCurrentPrimary` and `.invalidPromotionTarget` remain distinct cases — same shape as `ErrorCollapseConventionTests`), `testAcknowledge_propagatesEveryFirestoreErrorCaseDistinctly` in `AlertsRepositoryTests.swift`, and `test_actorIsPrimary_flipsWhenActorRoleMutatesInCoreData` in `SupervisorDashboardViewModelTests.swift`. That last one is the reactivity-fix regression test: it loads the view model, mutates the actor's `Person.role` directly in Core Data on the same view context, polls briefly, and asserts `viewModel.actorIsPrimary` flipped without a manual reload. To make it work I also needed to thread the test's in-memory `CoreDataStack` into the view model's init (default was `.shared`, which would have attached the observer to the wrong context); added `stack:` and `alertsRepo:` parameters to the view model's initializer.

Observability went in at the five transition points the playbook needs. `AlertsRepository.acknowledge` logs entry, Firestore success, Core Data mirror complete, and each distinct error case (so a Console filter on `com.medication.dosely:alerts` reads as a diagnosis trail). `FirestoreService.acknowledgeAlert`'s transaction logs a `txn attempt #N` line each time the closure invokes — Firestore can retry up to 5 times, and the "ack succeeded but UI didn't update" class of bug usually shows as multiple attempts where only the first writes. `PersonRepository.promoteToPrimary` logs entry, Firestore success, Core Data mirror complete, and each distinct preflight / Firestore failure case under `com.medication.dosely:role-transitions`. `FirestoreService.applyPrimaryAssignment` logs the batch start, every individual write path (circle, person, membership) at debug level, and success/failure at info/error. `SyncCoordinator.mirrorAlerts` logs `listener: remote ack received` for every snapshot row whose `acknowledgedBy` is non-empty — that single line is the second device's diagnostic signal that the first device's ack reached them. Privacy markers are explicit: `.public` for ids, UIDs, role strings, alert ids; medical-id free text never flows through these logs. The reason for all this verbosity is exactly the prompt's setup — manual test on two physical devices, hardest-to-observe transition points, no ability to attach Xcode to both simultaneously. Console.app filtered to the subsystem becomes the primary diagnostic tool.

The playbook lives in `docs/manual_tests_prompt18.md`. Each test has preconditions, tap-target-level steps, the exact Console.app log lines expected on each device, and failure-capture instructions. Test G explicitly documents both acceptable outcomes (ack lands before vs after the role transition propagates) — same alert text, same attribution, different code path through the rules layer.

Files touched: `Dosely/Data/FirestoreService.swift`, `Dosely/Data/AlertsRepository.swift`, `Dosely/Data/PersonRepository.swift`, `Dosely/Data/SyncCoordinator.swift`, `Dosely/Features/Supervisor/SupervisorDashboardView.swift`, `Dosely/Features/Supervisor/SupervisorDashboardViewModel.swift`, `Dosely/Features/Supervisor/People/PersonDetailView.swift`, `Dosely/Resources/en.lproj/Localizable.strings`, `Dosely/Resources/pa.lproj/Localizable.strings`, `tests/firestore_rules.test.ts`, `DoselyTests/AlertsRepositoryTests.swift`, `DoselyTests/PersonRepositoryTests.swift`, `DoselyTests/SupervisorDashboardViewModelTests.swift`, plus pre-existing compile fixes in `DoselyTests/MissedDoseDetectorTests.swift` and `DoselyTests/AlertsCardSmokeTests.swift` (see the "Discovered but not fixed" section below).

Reflection: the only finding that actually MIGHT not have surfaced under the manual run alone is the reactivity gap. Test G as written has Aunt 1 initiating the swap herself, so the local Core Data write happens immediately, `PersonDetailView` dismisses, and on her next tab change to Today the view body re-renders — the bug would have been invisible. The remote-driven case (Aunt 2 promotes Aunt 1 while Aunt 1 is foreground on Today) is what manifests it, and that wasn't in any of the manual test scripts I'd written. The audit pulled it forward because the audit's question was "is the role read reactive?" not "does the script work?" — and the answer was no even though the script would have looked fine. The lesson worth keeping: scripted tests verify the happy path of the script, not the surrounding behavior. The audit is what surfaces the dark corners.

## May 28 — tightened `isOrphanFounder`, cleared every pre-existing rules-test failure, deployed

The helper at `firestore.rules:213` was over-permissive in the exact shape the May 27 "Discovered but not fixed" section diagnosed. The doc comment promised "founder anchor AND absence-of-membership"; the implementation only checked the founder anchor — the careCircle's `primarySupervisorPersonID` resolves to a Person doc whose `firebaseUID == request.auth.uid`. Every healthy primary supervisor satisfies that anchor as a side effect of being primary, so every `match` block that ORs `isOrphanFounder` in as an escape hatch was silently letting the primary do whatever the helper unlocked. The three rules-test failures named on May 27 all traced to the same root cause: `denies a sole supervisor from deleting their own Person doc` hits the Person delete rule at `firestore.rules:448`, whose `isOrphanFounder` short-circuits past the supervisorCount-and-primary-change checks; `denies the primary from leaving without atomically promoting a secondary` hits the same rule and the same short-circuit; `alerts cannot be deleted by any supervisor` hits the alert delete rule at `firestore.rules:641` which is gated exclusively on the helper. Three tests, one helper.

The fix adds the missing conjunct:

```
(
  !exists(/databases/$(database)/documents/userMemberships/$(request.auth.uid)) ||
  get(/databases/$(database)/documents/userMemberships/$(request.auth.uid)).data.careCircleID != circleID
)
```

The two flavours of absence cover the two operational shapes. The migration-time shape is the production case I most cared about — `OrphanCircleCleanupMigration` runs from the user's REAL circle, so their `/userMemberships.careCircleID` already points at someplace OTHER than the orphan they're tearing down; the second disjunct is what makes the helper still return true for the migration's deletes. The membership-doesn't-exist shape covers a wipe-or-never-written edge case. Updated the doc comment to spell out exactly what each disjunct is for, because the previous comment's drift from the code is what let this ship in the first place.

Re-ran the full emulator suite. The three named failures all pass now. The fourth — `cascade delete after Person is gone is permitted` with the `Firestore has already been started` SDK error — turned out to be a test-isolation problem inside a single test body, not a rules issue. The failing test called `withSecurityRulesDisabled` with both a `setDoc` AND a `deleteDoc` on related paths inside the same admin callback, and the subsequent `authenticatedContext().firestore()` setting application tripped on a partially-torn-down admin Firestore lifecycle. Splitting the two admin operations into two separate `withSecurityRulesDisabled` calls — each completing before the next begins — cleared it. Same end state, no behavior change.

Added two new positive tests for `isOrphanFounder` so the contract is explicitly pinned: one where the founder has NO `/userMemberships` row anywhere (proving the first disjunct works), one where a healthy primary's helper invocation returns false (the regression the May 27 backlog flagged, now proven false in the suite). Final pass count: 89 from the post-Prompt-18 baseline of 83. Three previously-failing tests flipped to passing, two new positive tests added, one test-isolation fix.

Deployed at `2026-05-28 11:24 PDT` via `firebase deploy --only firestore:rules` from the repo root. The CLI confirmed "✔ Deploy complete!" against project `dosely-df5ca`. Recording the timestamp here so the next investigation has an audit trail against the Firebase Console's Published time — the rules-tests-pass-but-production-fails class of bug has bitten this project twice (April 30 phantom join code, May 27 medical-ID save) and the deploy line is what either confirms or refutes "is the live ruleset the one I'm looking at?"

The pattern worth marking: `isOrphanFounder` is a helper-shaped predicate, and rules written as `match { allow delete: if helperX(...) }` mean the helper IS the entire correctness surface. Helper drift is the entire failure mode. The `delete: false` lazy-safe default doesn't have this problem because there's no helper to drift — but `delete: false` is the pattern section 14.4 of the handoff explicitly forbids, because legitimate cleanup needs a delete path. The right shape is "delete: deniedInSteadyState && permittedUnderPreciselyEncodedCondition," and writing that pattern costs you exactly one carefully-shaped helper per delete that can fire. Today's bug was helper drift between comment and code. The way it got caught was the May 27 audit pulling the test target's compile back up; the rules tests had been failing all along but the test target hadn't built since the `replaceSchedules`-private-method regression in `MissedDoseDetectorTests`. Two prompts in a row now where the real bug surfaced from looking at things that weren't on anyone's checklist — May 27's reactivity gap, today's helper drift. The checklist-driven audit is good for the obvious cases; the curiosity-driven audit is what finds the silent ones.

Also pruned three entries from the "Still pending" trailer at the bottom of this file: the Prompt 18 e/f/g manual test plan (shipped in `b91728a` with the playbook at `docs/manual_tests_prompt18.md`), the Edit Medical ID screen item (shipped in `43a0b29` / `b2c1e87` / `acd03c6`, working on devices May 27 after the rules deploy), and the Prompt 19 real-time alerts item (shipped in `7faca6c` / `71f7746` / `eedbdbc`). Added a `<!-- Trailer last pruned 2026-05-28 -->` header note. Left every other trailer entry alone; in particular, the Face ID items and Prompt 10/11 backlog entries remain because their resolution status isn't unambiguous from the codebase alone.

Files touched: `firestore.rules`, `tests/firestore_rules.test.ts`, `build_log.md`. The Swift app side is untouched — this was purely a rules-layer + tests + deploy + doc cleanup.

## May 28 — closed the post-Prompt-18 Swift test failures (error-type, timezone, walker triage)

`b91728a` got the `DoselyTests` target compiling again after the `replaceSchedules`-private regression had kept it dark for weeks; the moment it built, the runtime failures the "Discovered but not fixed" section below had catalogued all came due at once. This is the cleanup pass that closes them.

Baseline first, and the baseline itself had a wrinkle worth recording. The full suite stalled the first time I ran it: every emulator-gated suite from `FirestoreServiceTests` onward retried against a Firestore emulator that wasn't running, each with backoff, so after roughly ten minutes the run had crawled only as far as suite "F". Killed it (`pkill -f "xcodebuild.*Dosely"`, exit 144), started `firebase emulators:start`, confirmed `127.0.0.1:8080` answering, and re-baselined against a live emulator. The takeaway for the next person: a "hanging" Swift run is usually the emulator-gated suites backing off, not a deadlock — start the emulator before you trust a baseline.

The May 27 backlog named six failures in three shapes. The actual list matched those six and added a seventh the backlog never caught — and the seventh is the deviation worth flagging. `MedicalIDRepositoryTests.testRemovePersonFromCircle_cascadesToMedicalIDRow` was not an assertion failure; it was a hard crash. `MedicalIDRepositoryTests.swift:215` force-unwrapped `grandpa.id!` *after* the line above it had called `removePersonFromCircle(personID: grandpa.id!)`, which deletes the `grandpa` managed object. A deleted `NSManagedObject` faults its properties back to nil, so the post-delete `grandpa.id!` hit nil and the process aborted with `Fatal error: Unexpectedly found nil`. A fatal-error crash reads nothing like an assertion failure in the log — it aborts the launch and triggers an xcodebuild relaunch that resumes *past* the dead test, so the totals never reconcile and you get the contradictory `** TEST FAILED **` sitting next to a clean `Executed 106 tests, with 0 failures` from the relaunch. Whoever wrote the May 27 backlog was almost certainly scanning for `error: -[...]` assertion lines and the crash simply doesn't surface that way. Fix is one line of discipline: capture `let grandpaID = grandpa.id!` before the delete and use the local for the seeding, the delete call, and the post-delete fetch. The test still proves exactly what it claims — Person removal cascades to the MedicalID row — without reaching through a tombstoned object.

**Part 2 — the error-type mismatch was the test's bug, not the repository's.** `testSave_throwsOfflineAndLeavesLocalCacheUntouchedWhenFirestoreMissing` failed `expected .offline, got offline`: two different error types (`MedicalIDRepositoryError.offline` and `FirestoreServiceError.offline`) that print the same string and compare unequal. The instinct is to "fix the repository," but `MedicalIDRepository.save` (lines 100–110) was already correct — it catches each `FirestoreServiceError` case and rethrows the matching `MedicalIDRepositoryError`, grep-marker comment and all, exactly as the error-collapse convention demands. The leak the test was accidentally tolerating *is the regression the convention exists to catch*: a raw `FirestoreServiceError` reaching a UI catch site means the user gets "check your connection" copy for a permission denial. So I fixed the test to assert the domain case and to `XCTFail` loudly with a convention-citing message if a raw service error ever leaks through. Added `testMedicalIDRepositoryError_allFourCasesAreMutuallyDistinct` mirroring `ErrorCollapseConventionTests` — pairwise distinctness across all four cases, so a future "simplify the error enum" PR fails here.

**Part 3 — timezone, and the contract stays local.** `testRunIfDueProducesDeterministicAlertID` and `testWeekEndingSundayGatedAtSixPM` both failed because the test built its dates with `components.timeZone = TimeZone(secondsFromGMT: 0)` (UTC) while the gate computes against the calendar's own zone. The user-facing contract is correct and non-negotiable — the grandparent in BC sees her weekly summary at *her* Sunday 6pm, local — so production stays local-time; the test was wrong, not the gate. Reworked the tests to construct dates in the calendar's timezone via a `gregorian(in: TimeZone)` helper defaulting to `America/Vancouver`, and changed `makeDate` to stamp `components.timeZone = calendar.timeZone`. One production touch went in alongside: `AlertID.weeklySummary` in `FirestoreModels.swift` now sets `formatter.timeZone = calendar.timeZone` before formatting the ISO date. Without it the deterministic doc id is computed in UTC — a Sunday-evening-Pacific summary would mint a *Monday*-dated id (the UTC rollover), which would split what is supposed to be one converged doc across two devices straddling the boundary. The id has to be computed in the same zone the gate fires in or the whole "deterministic id = the agreement" property breaks. Added `testGateFiresOnlyAtSundaySixPMLocal` to pin the contract end to end: Saturday 23:59 local → no fire, Sunday 18:00:00 local → fires, Monday 09:00 local → already fired, no re-fire.

**Part 4 — the four walker tests share one root cause, so the triage splits on whether the proof was salvageable.** Under recent iOS, SwiftUI no longer materialises `Text` as `UILabel`s in the offscreen UIView tree of a headless `UIHostingController`, so every "host the view, walk the hierarchy, assert on visible text" helper returns `[]`. These tests were catching the framework, not a regression — they'd have gone red the instant the target compiled regardless of app correctness. No `XCTSkip`, no `xfail`; each test either earns its place or is deleted.

- `AlertsCardSmokeTests` → **restructured**, because the logic it reached for was extractable. The type→presentation switch (icon, severity colour, body copy) and the three-way ack-row state are real branches worth guarding. I pulled them into pure statics on `AlertsCard` — `iconName`/`severityColor`/`bodyText`/`formattedTime` made `static`, plus a new `AckState` enum and `ackState(for:)` — and rewrote the tests to hit those directly. Same proof the render walk was groping for, no opaque tree. Confirmed no external callers of the now-static methods before changing their shape.
- `EditMedicalIDViewTests.test_editMedicalIDView_rendersPickerWhenTargetIsAbsent` → **deleted**. Its only honest claim — which arm the view picks for a given target state — is already covered exhaustively by the three pure `shouldShowTargetPicker` decision-logic tests in the same file. Left those three untouched, as instructed.
- `AddMedicationFlowTests` → **deleted** both render tests; kept the four `shouldShowTargetPicker` decision tests. Identical reasoning: the blank-sheet regression is guarded by the branch logic, which is tested directly.
- `PullToRefreshTests` → **deleted** the three `_rendersUIScrollView` tests; kept the three `SyncCoordinator.refresh` tests (one emulator-gated). That a tab wraps its body in a `ScrollView`/`List` is verifiable by reading the source, and `.refreshable` behaviour is an on-device concern an offscreen tree walk can't prove anyway — the walk was false confidence either way.

Every deletion left a class doc comment behind explaining what the walker tests were, why they were unreliable, and where the real proof now lives, so the next reader doesn't "restore" them.

**Part 5 — green.** Full suite: **209 tests, 0 failures, 0 unexpected**, single launch, `** TEST SUCCEEDED **`, zero `TEST FAILED`, no `Restarting after…` line, no `Fatal error`, no assertion lines. The contrast with the run just before the crash-fix is the whole story of why the seventh failure was easy to miss: that run reported a muddled `106 tests` spread across a crashed launch plus a relaunch and printed a spurious `** TEST FAILED **` next to `0 failures`. The force-unwrap had aborted the first launch early; the relaunch resumed past the dead test and counted only what was left. Fixing the one unwrap collapsed it back to a single clean launch and the true full-suite count surfaced. I don't have a precise pre-count to subtract against — the first baseline was interrupted by emulator backoff before it completed — so the honest delta is qualitative: seven previously-failing tests resolved (four fixed: one error-type, two timezone, one crash; `AlertsCardSmokeTests` restructured to five pure-helper tests), five render-walk tests deleted, three contract/distinctness tests added. Net, the suite that couldn't go red now runs 209 green in one pass.

The throughline across the last three prompts is a test target that couldn't fail because it couldn't build. A suite that doesn't compile runs zero tests and reports nothing red — and "no failures" and "no tests ran" look identical from across the room. The rules tests had been silently failing for the same reason for weeks; `b91728a` lifting the compile is what made *both* the rules failures (closed in the isOrphanFounder entry above) and these seven Swift failures visible on the same afternoon. The danger was never a red test. It was a suite that had quietly lost the ability to go red, while every glance at it said "fine." The fix this prompt actually delivers isn't seven test patches — it's the suite getting its voice back.

Follow-up, flagged not implemented: a pre-push hook that runs `xcodebuild build-for-testing` (compile only, no execution) would catch the un-buildable-target class at the moment it's introducible, instead of weeks later when someone happens to look. It is the same shape as the `firebase deploy --only firestore:rules --dry-run` hash-diff hook the May 27 entry flagged for the un-deployed-rules class — both verify that the artifact you're about to depend on is actually in the state you assume it's in. Whoever picks up pre-push hooks should do both at once; they're one habit, not two. Holding off on writing either into `CLAUDE.md` until Josh decides he wants the hook layer, but the prior art for this one is now two entries deep.

Files touched: `DoselyTests/MedicalIDRepositoryTests.swift`, `DoselyTests/WeeklySummaryGeneratorTests.swift`, `DoselyTests/AlertsCardSmokeTests.swift`, `DoselyTests/EditMedicalIDViewTests.swift`, `DoselyTests/AddMedicationFlowTests.swift`, `DoselyTests/PullToRefreshTests.swift`, `Dosely/Features/Supervisor/Components/AlertsCard.swift`, `Dosely/Data/FirestoreModels.swift`, `build_log.md`. No `firestore.rules` change — this prompt was Swift-test-side only.

## Discovered but not fixed in this prompt

These showed up while doing Prompt 18 work. None of them are caused by the changes in this prompt; they were always present, in some cases hidden by the test target's pre-existing compile failure.

**Rules tests: four pre-existing failures unrelated to e/f/g.** `tests/firestore_rules.test.ts` had 4 failing tests on `main` before my additions. `denies a sole supervisor from deleting their own Person doc`, `denies the primary from leaving without atomically promoting a secondary`, `alerts cannot be deleted by any supervisor`, and `cascade delete after Person is gone is permitted`. The first three look like they hit `isOrphanFounder` returning true for the current primary (because the helper doesn't actually verify "no current membership"); the fourth is a Firestore-emulator `Firestore has already been started` error that looks like test isolation. Confirmed pre-existing by stashing my changes and running against the bare `main`. Not fixed because they're outside the e/f/g surface area — flagging here so the next reader sees them.

**Test target had pre-existing compile errors.** `DoselyTests/MissedDoseDetectorTests.swift:144` called `medRepo.replaceSchedules(for:actorPersonID:schedules:)` which is private on `MedicationRepository`. `DoselyTests/AlertsCardSmokeTests.swift:99` referenced `Alert` as a return type, which is ambiguous because SwiftUI also has an `Alert`. Neither would compile, which meant the *entire* DoselyTests target wouldn't build — the rules-tests and ErrorCollapseConventionTests etc. compiled but no Swift test could run. I fixed both minimally to land my own Swift tests: replaced the private `replaceSchedules` call with the production-public `saveMedication(id:)` shape, and qualified `Alert` as `Dosely.Alert` in the smoke test file.

**With the test target compiling, several pre-existing runtime failures became visible.** `AlertsCardSmokeTests` finds an empty visible-text array — the `UIHostingController` walks isn't finding the SwiftUI labels (some interaction with how SwiftUI renders into a UIView hierarchy under headless test conditions). `EditMedicalIDViewTests.test_editMedicalIDView_rendersPickerWhenTargetIsAbsent` has the same shape. `PullToRefreshTests.test_*_rendersUIScrollView` is also a view-hierarchy walking issue. `WeeklySummaryGeneratorTests.testRunIfDueProducesDeterministicAlertID` and `testWeekEndingSundayGatedAtSixPM` look like time-based test issues (the Sunday-at-6pm gate isn't firing — possibly a timezone offset). `MedicalIDRepositoryTests.testSave_throwsOfflineAndLeavesLocalCacheUntouchedWhenFirestoreMissing` fails with `expected .offline, got offline` — looks like it's comparing `MedicalIDRepositoryError.offline` against `FirestoreServiceError.offline` and the values are different types. `AddMedicationFlowTests` similar UI-render-hierarchy issue.

None of these are in the e/f/g audit surface. They predate this prompt. The new tests I added pass cleanly; nothing I changed introduced these failures — they were always going to happen the moment the target could compile. Listing them here as the "discovered but not fixed" backlog so the next session has them queued.

**`isOrphanFounder` is over-permissive.** The rule doc comment (`firestore.rules:213`) says it should be true only when "the requester does NOT currently have a /userMemberships entry pointing at that circle," but the implementation only checks `careCircle.primarySupervisorPersonID` resolves to a Person doc with matching `firebaseUID`. The current primary of a healthy circle satisfies that. This is the root of the three "delete is unexpectedly allowed" failures above. Tighten the helper to also require `!exists(/userMemberships/$(request.auth.uid))` OR `get(/userMemberships/$(request.auth.uid)).data.careCircleID != circleID`. Out of scope for this prompt because it touches rules in a way that needs its own emulator-tests pass and a `firebase deploy --only firestore:rules` afterwards, but flagging the diagnosis.

## May 28 — Emergency Medical ID: read-only paramedic viewer, three entry points (Phase 2, Part 1)

Prompt 11 — the lock-screen-accessible emergency ID for paramedics — was skipped in the original sequence and has been sitting in the "Still pending" trailer ever since. This prompt builds the part of it that's actually reachable under free Apple Developer signing: an in-app, read-only, large-format view of a person's allergies, blood type, conditions, and emergency contacts, plus the three places a caregiver reaches it. The lock-screen half — the part that was the whole point of "lock-adjacent" — is explicitly NOT here, and the gap is worth dwelling on at the end.

**Part 1 — the read path, audited before a line of UI.** The viewer has one hard constraint: a paramedic holding the phone has no time for a loading spinner and may have no signal at all, so the screen has to render from cache, synchronously, in `init`. `MedicalIDRepository` already had an async `fetchLocal`; I added a synchronous sibling, `fetchLocalSync(personID:)` (`MedicalIDRepository.swift:51`), that runs the same fetch inside `context.performAndWait` and is documented main-thread-only (its only caller is the SwiftUI viewer, and `viewContext` is main-queue bound). The decode reuses the editor's `FMedicalID` semantics — same `decodeStringList` / `decodeContacts` parse — so the viewer and `EditMedicalIDView` can never disagree about what a row means. There is deliberately no SyncCoordinator listener for medical IDs; they hydrate only via the editor's `loadRemote` or a local-save mirror. To cover the "another supervisor edited it five minutes ago" case the viewer fires one best-effort `loadRemote` from `.task`, silently — if it fails the cached read has already painted the screen, which is exactly the offline contract.

**Part 2 — `EmergencyMedicalIDView`.** Header band first: a 120pt circular avatar, the name in `.dsTitleLarge()`, and a date-of-birth-plus-age line underneath. Then a blood-type chip (dsDanger text on a 15%-tint danger background over the white surface — high contrast, reads at arm's length), allergies and conditions as list cards, emergency contacts as `tel://` call buttons, and a notes card. Every section is suppressed when its field is empty — a skipped section forces a paramedic to verify actively, whereas "Allergies: none" reads as a positive all-clear assertion they might trust against an incomplete record, which is the more dangerous failure. The missing-record path is a single clean empty card ("No emergency information saved yet."), no placeholder dashes. All DS tokens, dsBackground behind dsSurface cards, NavigationStack + ScrollView. The file clears 200 lines (248 with its doc header), which the convention frowns on — but every section is its own computed subview and all the decision logic lives in a separate value type, so the body itself stays short; I'd rather carry the honest line count than inline the helpers to game it.

**Part 3 — three entry points, each shaped to its surface.** (3a) On TodayView a client now sees a blue "Emergency Medical ID" tile (`heart.text.square.fill`), deliberately distinct in colour, icon, and copy from the red "I need help" alert button below it — a paramedic glancing at the screen must not confuse a read action with an alarm. The alert button stays device-client-only (managed clients don't sign in to fire it); the Medical ID tile shows for any client. (3b) PersonDetailView gets a "View" row at the top of its medical section with a chevron, opening the viewer as a sheet. (3c) SupervisorDashboardView's Quick Actions card grows a "View Emergency Medical ID" action as a sibling to the existing Edit, routed through a small `MedicalIDViewerSheet` wrapper that reuses `AddMedicationTargetPicker` to choose whose ID to show — the same person-picker pattern the Add-Medication and Edit flows already use. All new copy is in `en.lproj` and mirrored into `pa.lproj` as `// REVIEW NEEDED` drafts, per the standing rule that no Punjabi ships to clients before the fluent-speaker review.

**Part 4 — tests, no render-walks.** Eighteen new tests across three files. `EmergencyMedicalIDViewModelTests` (11) pin the pure value type: empty-state collapse (no record vs. a row whose every field is blank, which must read identically), the DOB-only case that must NOT collapse, each section predicate flipping with content, age math straddling the birthday, and the `tel:` sanitiser stripping formatting / leading-plus / no-digit cases. `EmergencyMedicalIDViewTests` (5) is the @MainActor file: a populated record and a no-record person each build and lay out in a `UIHostingController` without crashing (exercising the real init → sync-read → view-model decode path), plus a decode-integrity round-trip and the eligibility gate. `EmergencyMedicalIDLocalizationTests` (2) resolves all 14 keys in both `en` and `pa` bundles, catching the "raw key leaked into the UI" failure mode and the "English string added without its Punjabi mirror" one. None of these walk the UIView tree for label text — that's the walker-triage lesson from earlier today honored from the start rather than re-learned: SwiftUI doesn't materialise `Text` as `UILabel`s offscreen, so such walks are vacuous. To keep the eligibility test from being vacuous in the other direction, I lifted the client-vs-supervisor predicate to a tested static, `EmergencyMedicalIDViewModel.isEligibleForMedicalID(role:)`, and pointed `TodayView.isClientActor` at it — the test now exercises the exact code production runs. Full suite, emulator up: 227 tests, 0 failures, single launch, `** TEST SUCCEEDED **` (209 baseline + 18).

**Part 5 — accessibility audit.** This came out documentation-only; the view satisfied every requirement as built, and I resisted adding anything just to have a diff. VoiceOver order follows the single leading VStack — name → DOB → blood type → allergies → conditions → contacts → notes — and the avatar is `.accessibilityHidden(true)` so it doesn't announce a decorative image ahead of the name. The blood-type chip is one combined element ("Blood type O+") rather than two stray fragments. Each contact button ignores its children and carries an explicit label ("Call Aunt Bibi at 5 5 5 …", digits spoken one at a time) plus a hint ("Opens the phone app to call."); the phone glyph is hidden. Tap targets — contact buttons, list rows, the entry tiles — clear the 48pt WCAG floor via `minTapTarget`. Dynamic Type rides the `ds*` modifiers up through accessibility5, and `.fixedSize(horizontal: false, vertical: true)` on the wrapping text stops a long allergy or note from clipping. The one thing I consciously did NOT do is stamp `.accessibilityAddTraits(.isHeader)` on the section titles — it'd be a reasonable polish, but it's net-new behavior outside this prompt's surface and I'm not expanding the diff to chase it; flagging it as an optional future nicety instead.

One registration note for the next person: the five new files didn't compile until I hand-added them to `project.pbxproj`. This project uses explicit `PBXFileReference` entries, not synchronized folder groups, so a file on disk is invisible to the build until it's wired into the build-file list, the file-reference list, its group, and the target's Sources phase — four-to-six locations per file. "Cannot find 'EmergencyMedicalIDView' in scope" on a file that plainly exists is the tell.

The reflection worth leaving, unlabeled: what shipped today is the *in-app* emergency ID, and it's genuinely useful — a caregiver or a paramedic handed the unlocked phone gets the information in one tap. But Prompt 11's original framing was "lock-screen-accessible," and that adjective is doing real work. The scenario that actually matters — phone locked on the nightstand, grandmother unconscious, paramedic who has never touched this app — is the one this build does *not* serve, because reaching the viewer still requires an unlocked phone and knowing the app exists. That capability lives behind APIs this prompt scoped out: HealthKit's Medical ID (which iOS surfaces from the Lock Screen Emergency dialer for free), a Lock Screen widget, or a Live Activity. I kept the button copy honest on purpose — it says "Emergency Medical ID," never "view from the lock screen," so we aren't promising a paramedic something the build can't do. The distance between "read-only paramedic view" (done) and "paramedic can reach it on a locked phone" (not done) is the whole reason the "Still pending" line gets rewritten rather than deleted.

Phase 2 follow-ups, flagged not implemented: (1) **HealthKit Medical ID integration** — mirror allergies / conditions / blood type / contacts into the system Medical ID so the Lock Screen Emergency path surfaces them with no app involvement; this is the highest-leverage of the three and the one that actually closes the locked-phone gap. (2) **Lock Screen widget** — a glanceable entry that at least advertises the ID exists. (3) **Live Activity** — a longer-lived surface for an active emergency. All three need entitlements and on-device verification, and HealthKit specifically wants its own privacy-string and consent pass; none are in this prompt's scope.

Files touched: `Dosely/Features/Supervisor/MedicalID/EmergencyMedicalIDView.swift` (new), `Dosely/Features/Supervisor/MedicalID/EmergencyMedicalIDViewModel.swift` (new), `Dosely/Data/MedicalIDRepository.swift`, `Dosely/Features/Today/TodayView.swift`, `Dosely/Features/Supervisor/People/PersonDetailView.swift`, `Dosely/Features/Supervisor/SupervisorDashboardView.swift`, `Dosely/Features/Supervisor/Components/QuickActionsCard.swift`, `Dosely/Resources/en.lproj/Localizable.strings`, `Dosely/Resources/pa.lproj/Localizable.strings`, `Dosely.xcodeproj/project.pbxproj`, and three new test files `DoselyTests/EmergencyMedicalID{ViewModel,View,Localization}Tests.swift`. No `firestore.rules` change — Phase 2 is app-side only.

## May 28 — Dark-mode DSColors was already done; closed the audit, the adaptive guard, and the trailer that lied

The prompt that opened this session was written to fix "invisible text on a real iPhone in dark mode" — `DSColors` tokens stored as fixed sRGB hex literals that don't react to `userInterfaceStyle`, so `dsTextPrimary` (#1A202C, near-black) lands on a system dark container and vanishes. It asked me to convert every token to an asset-catalog Color Set, audit the codebase for literal bypasses, add contrast and "actually differs between modes" tests, split the previews, and prune the backlog.

The first read killed half of it. `DSColors.swift` is already adaptive — every token is `adaptive(light:dark:)` over `UIColor(dynamicProvider:)`, dark variants tuned to clear WCAG AA, and `DSColorsContrastTests` already holds eight light + eight dark contrast cases. `git log -- DSColors.swift` named the culprit: commit `8481ab9`, "fix: make DSColors adaptive across light and dark mode, add contrast tests," dated **April 25** — a month ago. The fix shipped, was validated on device, and was then never written up here and never pruned from "Still pending," so the backlog has advertised an open dark-mode bug that hasn't existed since April. The prompt trusted the trailer; the trailer was stale.

So this session is the cleanup the April fix skipped, plus the parts of the prompt that were genuinely still open. The one fork — Part 2's "migrate the programmatic implementation to asset-catalog Color Sets" — I put to Josh, because it had stopped being a fix and become a rewrite of working code. He chose to keep the programmatic implementation. Right call: both mechanisms resolve per-trait identically at runtime, the programmatic one is already on the phone passing its tests, and the asset-catalog upside is tooling-preview niceness, not behaviour. Churning a validated fix for zero functional gain is how a regression gets shipped into something that was fine.

**The audit — the half that was real work.** Swept `Dosely/` for `Color.red/black/white/gray`, `Color(red:…)`, `Color(hex:…)`, `UIColor.…`, and `.foregroundColor`/`.background` literals. The honest finding: **not one fixed-literal bypass that breaks dark mode.** Every hit falls into one of four appearance-safe categories — white text/pills layered on a saturated DS fill (the contrast suite verifies white-on-fill ≥ 4.5:1 in both modes); `Color.black.opacity(…)` dimming scrims behind sheets, the count-badge backdrop, and the camera viewfinder (meant to be black regardless of appearance); `Color.gray.opacity(…)` for disabled controls, empty/future history cells, and progress tracks (`Color.gray` is itself trait-reactive, so these already adapt); and the `Color.black.opacity(0.06)` card shadow (fades against a dark surface by convention). I wrote the four categories up as a "Sanctioned non-token color usages" block at the top of `DSColors.swift` — the authoritative reference a future grep consults — and tagged the less-obvious core-UI sites (DoseCardView, DoseCell, StepShell, WeekPicker, CameraScanView) inline with "see DSColors audit note." The auth-flow scrims and disabled-button grays I left to the central block rather than stamp ten near-identical comments across five files; recording that scoping choice here so it doesn't later read as an oversight. I added **no new token** — the recurring disabled-gray was the one candidate, but `Color.gray` already adapts, and tokenizing it would mean inventing fixed light/dark values to mimic a system color I can't eyeball on-device this session. The design system is used correctly for every piece of content text and every surface; the bypasses are all deliberate.

**The guard the contrast tests were missing.** Contrast-in-both-modes already existed. What didn't: a test that a token actually *resolves differently* between light and dark. A token can pass every contrast assertion while silently non-adapting (someone copies the light hex into both arms of `adaptive`), and that non-adaptation IS the invisible-text bug. Added eight cases to `DSColorsContrastTests`: seven assert `UIColor(token).resolvedColor(with:)` yields a different `CGColor` under `.light` vs `.dark`, and the eighth pins the one deliberate exception — `dsWarning` is the same `#B45309` (amber-700) in both modes because it's the only weight that clears white-on-fill ≥ 4.5:1 in each direction (light `#D69E2E` failed at 2.39:1 on the Snooze button in April). That test asserts dsWarning resolves *identically* and says why, so a future "make warning adapt too" change has to consciously re-check the white-on-warning floor before it can go green. Suite: 227 → **235, zero failures**, single launch, emulator up.

**Previews.** `DesignSystemPreview` now renders an explicit Light and a Dark pass (plus the existing XXL-type pass). `EmergencyMedicalIDView` — the paramedic screen, the most accessibility-critical surface in the app — gets light and dark previews seeded by an in-memory factory that mirrors the `EmergencyMedicalIDViewTests` fixture, so the preview walks the real init → `fetchLocalSync` → decode path. `EditMedicalIDView` gets a dark form preview (a target id injected through the environment to force the form branch past the picker). `TodayView` and `MedicationDetailView` already carried dark previews, so I left them.

The dark palette, one line each so the rendering is inspectable against the previews without screenshots: **dsBackground** `#0F1419` is near-black with a faint blue-slate tint, deliberately not pure black so it's easier on the eyes at night; **dsSurface** `#1A202C` is a charcoal slate lifted just enough above the background that cards read as raised; **dsTextPrimary** `#F7FAFC` is the same off-white the light theme uses as a background, now carrying body text; **dsTextSecondary** `#A0AEC0` is a muted blue-gray for captions; **dsPrimary** `#2563EB` is a brighter royal blue than light's `#2B6CB0`, so it lifts off charcoal while still holding white text at AA; **dsSuccess** `#15803D` is a deep emerald; **dsWarning** `#B45309` is burnt amber, identical to light (the pinned exception); **dsDanger** `#DC2626` is a vivid red, a step brighter than light's `#C53030`.

One thing left deliberately untouched: commit `8481ab9` also added an "Always use light mode" toggle in Settings (`@AppStorage("force_light_mode")` feeding `.preferredColorScheme`). It defaults off, so the app follows the system and dark mode renders for anyone who hasn't opted out. The prompt's "no colorScheme toggle in Settings" line argues against it, but it shipped a month ago and pulling working Settings UI is a different change with its own testing — flagged, not done.

The reflection worth leaving: a backlog that lies costs more than an empty one. The dark-mode fix shipped April 25 and was correct; the only thing wrong was that "Still pending" never learned it was done, so a month later it generated a whole prompt to re-fix and re-mechanism a bug that didn't exist — and the asset-catalog half of that prompt would have rewritten a validated fix and risked a regression in the name of tidiness. The cheap defense is the one that almost didn't happen: open the file before trusting the line that says it's broken. Two of the remaining trailer items — both Face ID entries — smell the same way; commits `125e917` and `699a369` look like they closed them in April, but "look like" isn't "verified," so they stay until someone confirms on device — the same conservatism the isOrphanFounder entry applied earlier today. I pruned only the dark-mode line, because that's the one I read the code for.

Files touched: `Dosely/DesignSystem/DSColors.swift`, `Dosely/DesignSystem/DesignSystemPreview.swift`, `Dosely/Features/Supervisor/MedicalID/EmergencyMedicalIDView.swift`, `Dosely/Features/Supervisor/MedicalID/EditMedicalIDView.swift`, `Dosely/Features/Today/Components/DoseCardView.swift`, `Dosely/Features/History/Components/DoseCell.swift`, `Dosely/Features/History/Components/WeekPicker.swift`, `Dosely/Features/AddMedication/Components/StepShell.swift`, `Dosely/Features/AddMedication/Scan/CameraScanView.swift`, and `DoselyTests/DSColorsContrastTests.swift`. No `firestore.rules` change, no new files (so no `project.pbxproj` edit), no `firebase deploy`.

## Still pending

<!-- Trailer last pruned 2026-05-28 -->

- Face ID setup prompt after sign-up (queued — alert never appears)
- Face ID session-expired redesign — local-lock pattern (queued — biggest of the three Face ID issues)
- Multi-photo / video capture for wrapped labels (queued — pill bottles wrap text around the cylinder)
- Bundle ID alignment — update Firebase iOS app to `com.medication.dosely`, optionally retire the old `kSecAttrService` string in Keychain.swift
- Punjabi re-attempt — confirm with the family which **script** they actually read before re-running Prompt 12 (grandparents don't read Gurmukhi); audio-first may be the right shape
- Accessibility toggles polish (Prompt 10 was skipped — text-size override, high-contrast mode, voice readout helper)
- Emergency Medical ID Phase 2 — lock-screen reach for paramedics: HealthKit Medical ID integration (highest-leverage; closes the locked-phone gap), Lock Screen widget, Live Activity (in-app read-only viewer + three entry points shipped 2026-05-28)
- Real-iPhone scan test with an actual prescription bottle (simulator can't capture frames)
- Round 2 client testing — structured, with stopwatch and silent observation
- Portfolio cleanup: empty A.2 prioritization body, A.3, B.1, B.4 wireframes, leftover duplicate A.1 page




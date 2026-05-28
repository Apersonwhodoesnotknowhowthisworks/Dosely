# Prompt 18 — manual tests for ack / promote-to-primary / role transition

These are the steps to run on two physical devices for the e/f/g pending items from section 19 of the project handoff. The audit, automated coverage, and `os_log` instrumentation in this prompt mean the manual run is mostly a confirmation, not a discovery exercise — but each test still has explicit observation points so an unexpected silence is loud.

## Devices and roles

- **Simulator** — iPhone 17 Pro on iOS 26.4, signed in as `goon@gmail.com`. This account is **Aunt 1** and currently the **primary supervisor** of the "Test Family" circle.
- **iPhone** — real device, signed in as `joshbhangle@gmail.com`. This account is **Aunt 2** and currently a **secondary supervisor** of the same circle.
- **Grandpa (test)** — managed-client Person, dose-target only.

Both devices must show the same circle name on the dashboard before any test starts. If they don't, sign in / out to recover.

## Console.app setup (once per session)

On the Mac, open Console.app, select the simulator under **Devices** in the sidebar, and filter `subsystem:com.medication.dosely`. To watch the iPhone, attach it to Xcode (Window → Devices and Simulators), then Console.app → that device, same subsystem filter. The relevant categories are:

- `alerts` — ack flow, listener-driven ack delivery
- `role-transitions` — promote-to-primary, applyPrimaryAssignment batch writes
- `firestore` — the unmapped-error path (only fires on `.unknown`)

Keep both Console windows visible during the runs.

---

## Test E — alert acknowledgement, either device clears for both

### Preconditions

- A missed-dose alert exists for Grandpa (test) at `/careCircles/{id}/alerts/{alertID}` with `acknowledgedBy: null`. If one doesn't exist, schedule a dose for Grandpa earlier today and let the missed-dose detector mint one on the next foreground (the dashboard's `.onReceive(UIApplication.willEnterForegroundNotification)` triggers `reload()`, which runs the detector).
- Both devices have the supervisor dashboard open on the Today tab.
- The AlertsCard on both shows the same pending alert text and an enabled Acknowledge button.

### Steps

1. Confirm the alert is visible on both devices and the Acknowledge button is enabled on both.
2. On the **simulator**: tap **Acknowledge** on the alert row.
3. Within 5 seconds:
   - **Simulator UI**: the row reads "Acknowledged by [Aunt 1's name]"; the Acknowledge button is gone.
   - **iPhone UI**: same — "Acknowledged by [Aunt 1's name]"; button gone.
4. **Simulator Console.app** (filter `com.medication.dosely:alerts`): expect three lines in order:
   - `acknowledge: entry actor=<uid> alert=<id> circle=<id>`
   - `acknowledge: Firestore success alert=<id>`
   - `acknowledge: Core Data mirror complete alert=<id>`

   And from the `firestore` transaction:
   - `acknowledgeAlert: transaction start alert=<id>`
   - `acknowledgeAlert: txn attempt #1 alert=<id>` (additional `txn attempt #N` lines if Firestore retried)
5. **iPhone Console.app** (filter same): expect
   - `listener: remote ack received alert=<id> by=<Aunt 1's uid>`
6. Repeat with a **new** alert (let another missed dose accumulate) but tap Acknowledge on the **iPhone** this time. Simulator should now see the listener log line, and both UIs should converge on "Acknowledged by [Aunt 2's name]."

### Race-condition variant (optional, hard to time)

Both devices tap Acknowledge within ~1 second of each other on the same alert.

- Expected: one ack lands first, the other transaction sees a non-null `acknowledgedBy` after `txn.getDocument` and returns silently (no error toast).
- Both devices converge on the same "Acknowledged by ..." attribution within 5 seconds.
- Simulator Console (loser): a `txn attempt #1` line, no `Firestore success` follow-up.

### Failure modes

- Acknowledge button still enabled on the iPhone after the simulator's ack landed → listener didn't deliver. Capture the simulator's Console showing Firestore success and the iPhone's Console showing no `listener: remote ack received`.
- Acknowledge tap on simulator produces a "Couldn't reach the server" toast when the network is up → error-collapse regressed; the rule rejection is masquerading as offline. Capture both Console windows and the rule code path.

---

## Test F — promote-to-primary swap

### Preconditions

- Simulator (Aunt 1) is currently primary supervisor.
- iPhone (Aunt 2) is currently secondary supervisor.
- No active alerts on either device.

### Steps

1. On the **simulator**: tap the **People** tab in the bottom bar.
2. Tap on the row labeled with Aunt 2's name. This opens `PersonDetailView`.
3. Scroll. The "Make primary supervisor" row should be visible because the actor is currently primary AND Aunt 2 is another supervisor in the same circle.
4. Negative check for the affordance gate: sign out on the simulator, sign back in as Aunt 2 (`joshbhangle@gmail.com`), open People → Aunt 1's row. The "Make primary supervisor" row should NOT appear — secondaries can't promote anyone. (Sign back in as Aunt 1 before continuing.)
5. Tap **Make primary supervisor**. A confirmation alert appears.
6. **Verify the alert body** contains the phrase "you will become a secondary supervisor and won't be able to add or change medications." This is the bidirectional-swap warning; a confirmation alert that doesn't mention it is a copy regression.
7. Tap **Yes, make them primary**.
8. Within 5 seconds:
   - **Simulator**: the role badge at the top right flips from "Primary" to "View only". The QuickActionsCard ("+ Add medication", "Edit medical ID", "Settings") disappears. The "Edit Medical ID" affordance under People → Grandpa is gone too. The simulator now shows the secondary read-only notice in the Today tab.
   - **iPhone**: the role badge flips from "View only" to "Primary". QuickActionsCard appears. The Edit Medical ID affordance shows up.
9. **Simulator Console.app** (filter `com.medication.dosely:role-transitions`): expect, in order:
   - `promoteToPrimary: entry actor=<actor uid> target=<target uid>`
   - `applyPrimaryAssignment: batch starting circle=<id> newPrimary=<target> supervisorRows=2`
   - `applyPrimaryAssignment: write circle.primarySupervisorPersonID circle=<id>`
   - Two `write person.role` lines — one for the old primary going to `secondary_supervisor`, one for the new primary going to `primary_supervisor`
   - Two `write membership.role` lines for both supervisors
   - `applyPrimaryAssignment: success circle=<id> newPrimary=<target>`
   - `promoteToPrimary: Firestore success circle=<id> newPrimary=<target>`
   - `promoteToPrimary: Core Data mirror complete circle=<id>`
10. **Swap back**: on the **iPhone** (now primary), open People → Aunt 1 → Make primary supervisor → confirm. Both devices flip back to the original arrangement within 5 seconds.

### Failure modes

- The "Make primary supervisor" row appears on the simulator while Aunt 1 is already secondary → the dashboard's `isPrimary` computed property is reading stale state. The view model's `actorIsPrimary` observer should catch this; if it didn't, capture the actor's `Person.role` value from a debugger or from `Console.app:firestore` and check whether the listener-mirrored update fired.
- Promote confirmation succeeds but the iPhone's role badge doesn't flip → the listener didn't deliver the careCircle update to the iPhone. Look for a `firestore` error line on the iPhone's Console. Foreground-and-background the iPhone app — `reload()` runs on `willEnterForegroundNotification`.
- Either device shows a "couldn't complete that" toast → check the simulator's `role-transitions` Console for the specific case. `permissionDenied` means the rules layer rejected; `offline` means the network's flaky; `unknown` means an unmapped error landed in `Logger:com.medication.dosely:firestore`.

---

## Test G — role transition during active alert

### Preconditions

- Simulator (Aunt 1) is currently primary.
- iPhone (Aunt 2) is currently secondary.
- **One** unacknowledged missed-dose alert is visible on both devices. (Generate one as in Test E preconditions.)

### Steps

1. On the **simulator**: tap **People** → Aunt 2's row → **Make primary supervisor** → confirm.
2. Immediately (within ~5 seconds, before the listener has fully settled if possible): tap **Acknowledge** on the alert card on the simulator's Today tab. PersonDetailView dismissed itself in step 1 so the Today tab is what's showing now.
3. There are two acceptable outcomes. Document which one happened:

   **Outcome A — ack lands before the role transition fully propagates.**
   The simulator's actor was still primary at the moment the ack write hit Firestore; `isAnySupervisor` (the rules predicate on the alert update) returns true regardless, so the ack commits. Both devices converge on "Acknowledged by Aunt 1."

   **Outcome B — ack lands after the role transition propagates.**
   The simulator's actor is now secondary at the moment the ack write hits Firestore. `isAnySupervisor` still returns true (secondaries can ack — that's the e2 test in `tests/firestore_rules.test.ts`). Both devices converge on "Acknowledged by Aunt 1."

4. Either way: **NEITHER device should show an error toast**, and the alert should end up acknowledged on both. The "Acknowledged by ..." attribution is Aunt 1 in both outcomes.
5. **Simulator Console.app** (filter `com.medication.dosely`): expect a `role-transitions` sequence and an `alerts` sequence interleaved. Their exact ordering depends on which outcome you hit, but both should be present.
6. **Swap back** by promoting Aunt 1 again from the iPhone, so the next manual run starts from the same preconditions.

### Failure modes

- The simulator's Acknowledge button **disappears mid-transition** (the actor is now secondary and a stale view-model thinks the button should be hidden for non-primaries) → this is the reactivity gap Part 2c addressed. `AlertsCard.swift` should be rendering the button based on `alert.acknowledgedByFirebaseUID.isEmpty`, NOT on the actor's role. If the button vanishes, capture a screenshot and check whether the dashboard's `viewModel.actorIsPrimary` is firing through to anything that gates AlertsCard. (As currently written, AlertsCard doesn't read actor role at all — so a regression here means someone added a role gate.)
- Both devices show different "Acknowledged by ..." names → the rules layer let two acks land. Capture the alert doc from the Firebase Console and the simulator + iPhone Console logs filtered on the alertID.
- An error toast appears on the simulator after the ack tap → the role transition tripped a rules path that shouldn't have triggered. Capture the simulator's `role-transitions` + `alerts` + `firestore` Console output and the alertID from the doc.

---

## If anything fails — what to capture

1. Screenshots from **both** devices at the moment of the failure.
2. Console.app's `com.medication.dosely` filter exported as text for **both** devices, covering the 60 seconds before and after the failure. (File → Save As… in Console.app.)
3. The `/userMemberships/{uid}` doc contents for both signed-in users via the Firebase Console (Authentication → Users → click each → copy the uid; then Firestore → `userMemberships` → click that uid; copy the JSON).
4. The alert doc at `/careCircles/{circleID}/alerts/{alertID}` if Test E or G is the failing test.
5. The careCircle doc at `/careCircles/{circleID}` if Test F or G is the failing test (specifically the `primarySupervisorPersonID` field's current value).

The audit-then-test-then-instrument shape means most failure modes should already be diagnosed by the time the screenshots reach me — Console.app's filtered output usually answers the "what happened" question on its own.

/**
 * Unit tests for /firestore.rules.
 *
 * Run via:  npm test       (boots the emulator)
 *           npm run test:ci  (assumes the emulator is already running)
 *
 * The suite uses @firebase/rules-unit-testing. Seed data is written via
 * `withSecurityRulesDisabled` so each test starts from a known
 * consistent state (founder-bootstrap is exercised separately in the
 * "bootstrap" block).
 */

import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  doc,
  setDoc,
  getDoc,
  updateDoc,
  deleteDoc,
  writeBatch,
  serverTimestamp,
} from "firebase/firestore";
import { readFileSync } from "fs";
import { resolve } from "path";

// Matches the project id the local Firestore emulator uses by default
// (see firebase.json — `singleProjectMode: true` locks the emulator to
// a single id; the no-arg `firebase emulators:start` picks
// "demo-no-project"). Aligning with that lets the tests reuse a
// long-running emulator instead of fighting it for the port.
const PROJECT_ID = "demo-no-project";

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

let testEnv: RulesTestEnvironment;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(resolve(process.cwd(), "../firestore.rules"), "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

interface SeedSupervisor {
  uid: string;
  personID: string;
}

interface SeedDeviceClient {
  uid: string;
  personID: string;
}

interface SeededCircle {
  circleID: string;
  joinCode: string;
  supervisor: SeedSupervisor;
  deviceClient?: SeedDeviceClient;
}

/**
 * Seeds a fully-bootstrapped care circle: careCircle doc with
 * supervisorCount=1, /joinCodes index, founder's /userMemberships and
 * Person doc, optionally a device_client.
 *
 * `primarySupervisor` (default true) controls whether the founder is
 * stamped as `primary_supervisor` (post-split data) or `supervisor`
 * (legacy alias — exercises the transitional read path). `extraSupervisors`
 * are seeded as `secondary_supervisor` by default.
 */
async function seedCircle(opts: {
  circleID: string;
  joinCode: string;
  supervisor: SeedSupervisor;
  deviceClient?: SeedDeviceClient;
  supervisorCount?: number;
  extraSupervisors?: SeedSupervisor[];
  primarySupervisor?: boolean;
  legacyRoles?: boolean;
}): Promise<SeededCircle> {
  const supervisorCount = opts.supervisorCount ?? 1;
  const founderRole = opts.legacyRoles ? "supervisor" : "primary_supervisor";
  const extraRole = opts.legacyRoles ? "supervisor" : "secondary_supervisor";
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const circleData: Record<string, unknown> = {
      id: opts.circleID,
      name: "Test Family",
      joinCode: opts.joinCode,
      createdAt: new Date(),
      supervisorCount,
    };
    if (!opts.legacyRoles) {
      // Pre-migration data has no primarySupervisorPersonID — leave the
      // field absent so `.get('primarySupervisorPersonID', '')` in the
      // rules returns the empty default for legacy-mode tests.
      circleData.primarySupervisorPersonID = opts.supervisor.personID;
    }
    await setDoc(doc(db, `careCircles/${opts.circleID}`), circleData);
    await setDoc(doc(db, `joinCodes/${opts.joinCode}`), {
      careCircleID: opts.circleID,
      regeneratedAt: new Date(),
    });
    await setDoc(
      doc(db, `careCircles/${opts.circleID}/people/${opts.supervisor.personID}`),
      {
        id: opts.supervisor.personID,
        careCircleID: opts.circleID,
        name: "Founder Aunt",
        role: founderRole,
        languagePreference: "en",
        firebaseUID: opts.supervisor.uid,
        failedPinAttempts: 0,
      }
    );
    await setDoc(doc(db, `userMemberships/${opts.supervisor.uid}`), {
      careCircleID: opts.circleID,
      personID: opts.supervisor.personID,
      role: founderRole,
      joinedAt: new Date(),
    });

    for (const sup of opts.extraSupervisors ?? []) {
      await setDoc(doc(db, `careCircles/${opts.circleID}/people/${sup.personID}`), {
        id: sup.personID,
        careCircleID: opts.circleID,
        name: "Co-Supervisor",
        role: extraRole,
        languagePreference: "en",
        firebaseUID: sup.uid,
        failedPinAttempts: 0,
      });
      await setDoc(doc(db, `userMemberships/${sup.uid}`), {
        careCircleID: opts.circleID,
        personID: sup.personID,
        role: extraRole,
        joinedAt: new Date(),
      });
    }

    if (opts.deviceClient) {
      await setDoc(
        doc(db, `careCircles/${opts.circleID}/people/${opts.deviceClient.personID}`),
        {
          id: opts.deviceClient.personID,
          careCircleID: opts.circleID,
          name: "Grandpa",
          role: "device_client",
          languagePreference: "en",
          firebaseUID: opts.deviceClient.uid,
          failedPinAttempts: 0,
        }
      );
      await setDoc(doc(db, `userMemberships/${opts.deviceClient.uid}`), {
        careCircleID: opts.circleID,
        personID: opts.deviceClient.personID,
        role: "device_client",
        joinedAt: new Date(),
      });
    }
  });

  return {
    circleID: opts.circleID,
    joinCode: opts.joinCode,
    supervisor: opts.supervisor,
    deviceClient: opts.deviceClient,
  };
}

async function seedMedication(
  circleID: string,
  medicationID: string,
  personID: string,
  name = "Lipitor"
) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), `careCircles/${circleID}/medications/${medicationID}`),
      {
        id: medicationID,
        personID,
        name,
        dose: "20mg",
        pillsPerDose: 1,
        foodRule: "either",
        currentSupply: 30,
        dateAdded: new Date(),
      }
    );
  });
}

function authedDb(uid: string) {
  return testEnv.authenticatedContext(uid).firestore();
}

function unauthedDb() {
  return testEnv.unauthenticatedContext().firestore();
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

describe("Firestore security rules", () => {
  // -- 1. Signed-out access ---------------------------------------------

  describe("signed-out access", () => {
    it("cannot read any /careCircles document", async () => {
      const seeded = await seedCircle({
        circleID: "circle-A",
        joinCode: "111111",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });

      const db = unauthedDb();
      await assertFails(getDoc(doc(db, `careCircles/${seeded.circleID}`)));
      await assertFails(
        getDoc(doc(db, `careCircles/${seeded.circleID}/people/${seeded.supervisor.personID}`))
      );
    });

    it("cannot read /joinCodes either", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "222222",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });

      const db = unauthedDb();
      await assertFails(getDoc(doc(db, "joinCodes/222222")));
    });
  });

  // -- 2. /joinCodes -----------------------------------------------------

  describe("/joinCodes", () => {
    it("can be read by any signed-in user (cross-circle is fine)", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "333333",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });

      // A different user, not yet in any circle, can still read.
      const db = authedDb("stranger-uid");
      await assertSucceeds(getDoc(doc(db, "joinCodes/333333")));
    });
  });

  // -- 3. Cross-circle isolation ----------------------------------------

  describe("cross-circle isolation", () => {
    it("supervisor of A cannot read circle B's data", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "100001",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });
      await seedCircle({
        circleID: "circle-B",
        joinCode: "100002",
        supervisor: { uid: "aunt2-uid", personID: "person-aunt2" },
      });

      const aunt1 = authedDb("aunt1-uid");
      // Aunt 1 reads her own circle — fine.
      await assertSucceeds(getDoc(doc(aunt1, "careCircles/circle-A")));
      // Aunt 1 attempts to read circle B — denied.
      await assertFails(getDoc(doc(aunt1, "careCircles/circle-B")));
      await assertFails(
        getDoc(doc(aunt1, "careCircles/circle-B/people/person-aunt2"))
      );
    });

    it("supervisor of A cannot write into circle B", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "200001",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });
      await seedCircle({
        circleID: "circle-B",
        joinCode: "200002",
        supervisor: { uid: "aunt2-uid", personID: "person-aunt2" },
      });

      const aunt1 = authedDb("aunt1-uid");
      await assertFails(
        setDoc(doc(aunt1, "careCircles/circle-B/medications/forged-med"), {
          id: "forged-med",
          personID: "person-aunt2",
          name: "Forged",
          dose: "1mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 1,
          dateAdded: new Date(),
        })
      );
    });
  });

  // -- 4. Device client write boundaries --------------------------------

  describe("device client", () => {
    const circleID = "circle-A";
    const supervisor = { uid: "aunt1-uid", personID: "person-aunt1" };
    const grandpa = { uid: "grandpa-uid", personID: "person-grandpa" };
    const grandpaMedID = "med-grandpa-lipitor";
    const supervisorMedID = "med-aunt1-bp";

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "300001",
        supervisor,
        deviceClient: grandpa,
      });
      await seedMedication(circleID, grandpaMedID, grandpa.personID, "Lipitor");
      await seedMedication(circleID, supervisorMedID, supervisor.personID, "Lisinopril");
    });

    it("cannot create a medication", async () => {
      const db = authedDb(grandpa.uid);
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/medications/sneaky-med`), {
          id: "sneaky-med",
          personID: grandpa.personID,
          name: "Sneaky",
          dose: "5mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 10,
          dateAdded: new Date(),
        })
      );
    });

    it("can create a doseLog for THEIR OWN medication", async () => {
      const db = authedDb(grandpa.uid);
      const logID = "log-grandpa-1";
      await assertSucceeds(
        setDoc(doc(db, `careCircles/${circleID}/doseLogs/${logID}`), {
          id: logID,
          medicationID: grandpaMedID,
          loggedByPersonID: grandpa.personID,
          scheduledTime: new Date(),
          actualTime: new Date(),
          status: "taken",
        })
      );
    });

    it("CANNOT create a doseLog for another person's medication", async () => {
      const db = authedDb(grandpa.uid);
      const logID = "log-grandpa-on-aunt-med";
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/doseLogs/${logID}`), {
          id: logID,
          medicationID: supervisorMedID, // not grandpa's med
          loggedByPersonID: grandpa.personID,
          scheduledTime: new Date(),
          actualTime: new Date(),
          status: "taken",
        })
      );
    });

    it("CANNOT create a doseLog impersonating a different loggedByPersonID", async () => {
      const db = authedDb(grandpa.uid);
      const logID = "log-grandpa-impersonating";
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/doseLogs/${logID}`), {
          id: logID,
          medicationID: grandpaMedID,
          // claims a different personID, not grandpa's
          loggedByPersonID: supervisor.personID,
          scheduledTime: new Date(),
          actualTime: new Date(),
          status: "taken",
        })
      );
    });
  });

  // -- 5. /familyContacts privacy ---------------------------------------

  describe("/familyContacts", () => {
    const circleID = "circle-A";
    const supervisor = { uid: "aunt1-uid", personID: "person-aunt1" };
    const grandpa = { uid: "grandpa-uid", personID: "person-grandpa" };

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "400001",
        supervisor,
        deviceClient: grandpa,
      });
      // Seed a contact under admin auth.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(
          doc(ctx.firestore(), `careCircles/${circleID}/familyContacts/dr-smith`),
          {
            id: "dr-smith",
            name: "Dr. Smith",
            phone: "+1-555-0100",
          }
        );
      });
    });

    it("supervisors can read", async () => {
      const db = authedDb(supervisor.uid);
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/familyContacts/dr-smith`))
      );
    });

    it("device clients are denied", async () => {
      const db = authedDb(grandpa.uid);
      await assertFails(
        getDoc(doc(db, `careCircles/${circleID}/familyContacts/dr-smith`))
      );
    });
  });

  // -- 6. Last-supervisor protection ------------------------------------

  describe("last-supervisor protection", () => {
    it("denies a sole supervisor from deleting their own Person doc", async () => {
      const supervisor = { uid: "aunt1-uid", personID: "person-aunt1" };
      const seeded = await seedCircle({
        circleID: "circle-solo",
        joinCode: "500001",
        supervisor,
        supervisorCount: 1,
      });

      const db = authedDb(supervisor.uid);
      // Attempt #1: just a single delete, no count change.
      await assertFails(
        deleteDoc(doc(db, `careCircles/${seeded.circleID}/people/${supervisor.personID}`))
      );

      // Attempt #2: a batch that decrements count to 0 along with the
      // delete — also denied (post-batch supervisorCount must be >= 1).
      const batch = writeBatch(db);
      batch.delete(doc(db, `careCircles/${seeded.circleID}/people/${supervisor.personID}`));
      batch.update(doc(db, `careCircles/${seeded.circleID}`), { supervisorCount: 0 });
      batch.delete(doc(db, `userMemberships/${supervisor.uid}`));
      await assertFails(batch.commit());
    });

    it("allows a secondary supervisor to leave when the primary remains", async () => {
      const primary = { uid: "aunt1-uid", personID: "person-aunt1" };
      const secondary = { uid: "aunt2-uid", personID: "person-aunt2" };
      const seeded = await seedCircle({
        circleID: "circle-pair",
        joinCode: "500002",
        supervisor: primary,
        extraSupervisors: [secondary],
        supervisorCount: 2,
      });

      // Aunt 2 (secondary) leaves: batch { delete Person, decrement count, delete /userMemberships }.
      // primarySupervisorPersonID stays pointed at aunt 1, so the
      // primary-orphan rule is satisfied.
      const db = authedDb(secondary.uid);
      const batch = writeBatch(db);
      batch.delete(doc(db, `careCircles/${seeded.circleID}/people/${secondary.personID}`));
      batch.update(doc(db, `careCircles/${seeded.circleID}`), { supervisorCount: 1 });
      batch.delete(doc(db, `userMemberships/${secondary.uid}`));
      await assertSucceeds(batch.commit());
    });

    it("denies the primary from leaving without atomically promoting a secondary", async () => {
      const primary = { uid: "aunt1-uid", personID: "person-aunt1" };
      const secondary = { uid: "aunt2-uid", personID: "person-aunt2" };
      const seeded = await seedCircle({
        circleID: "circle-pair2",
        joinCode: "500003",
        supervisor: primary,
        extraSupervisors: [secondary],
        supervisorCount: 2,
      });

      // Primary tries to leave without promoting — count drops fine but
      // primarySupervisorPersonID would still point at the deleted Person.
      const db = authedDb(primary.uid);
      const batch = writeBatch(db);
      batch.delete(doc(db, `careCircles/${seeded.circleID}/people/${primary.personID}`));
      batch.update(doc(db, `careCircles/${seeded.circleID}`), { supervisorCount: 1 });
      batch.delete(doc(db, `userMemberships/${primary.uid}`));
      await assertFails(batch.commit());
    });
  });

  // -- 7. Person doc self-edit boundaries -------------------------------

  describe("Person self-edit", () => {
    const circleID = "circle-A";
    const supervisor = { uid: "aunt1-uid", personID: "person-aunt1" };
    const grandpa = { uid: "grandpa-uid", personID: "person-grandpa" };

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "600001",
        supervisor,
        deviceClient: grandpa,
      });
    });

    it("device client can change own languagePreference", async () => {
      const db = authedDb(grandpa.uid);
      await assertSucceeds(
        updateDoc(
          doc(db, `careCircles/${circleID}/people/${grandpa.personID}`),
          { languagePreference: "pa" }
        )
      );
    });

    it("device client cannot promote themselves to supervisor", async () => {
      const db = authedDb(grandpa.uid);
      await assertFails(
        updateDoc(
          doc(db, `careCircles/${circleID}/people/${grandpa.personID}`),
          { role: "supervisor" }
        )
      );
    });

    it("device client cannot edit somebody else's Person doc", async () => {
      const db = authedDb(grandpa.uid);
      await assertFails(
        updateDoc(
          doc(db, `careCircles/${circleID}/people/${supervisor.personID}`),
          { languagePreference: "pa" }
        )
      );
    });
  });

  // -- 8. /userMemberships rules ----------------------------------------

  describe("/userMemberships", () => {
    it("self-create as supervisor on a fresh (count=0) circle is allowed", async () => {
      // Manually seed a fresh circle (no supervisor yet) under admin.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), "careCircles/fresh-circle"), {
          id: "fresh-circle",
          name: "Pending",
          joinCode: "700001",
          createdAt: new Date(),
          supervisorCount: 0,
        });
      });

      const founder = "founder-uid";
      const db = authedDb(founder);
      await assertSucceeds(
        setDoc(doc(db, `userMemberships/${founder}`), {
          careCircleID: "fresh-circle",
          personID: "founder-person",
          role: "supervisor",
          joinedAt: new Date(),
        })
      );
    });

    it("self-create as supervisor on a populated circle without joinCode is denied", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "800001",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });

      const attacker = "attacker-uid";
      const db = authedDb(attacker);
      await assertFails(
        setDoc(doc(db, `userMemberships/${attacker}`), {
          careCircleID: "circle-A",
          personID: "attacker-person",
          role: "supervisor",
          joinedAt: new Date(),
          // no joinCode — no proof
        })
      );
    });

    it("self-create with a valid joinCode is allowed (joiner path)", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "800002",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });

      const joiner = "aunt2-uid";
      const db = authedDb(joiner);
      await assertSucceeds(
        setDoc(doc(db, `userMemberships/${joiner}`), {
          careCircleID: "circle-A",
          personID: "person-aunt2",
          role: "supervisor",
          joinedAt: new Date(),
          joinCode: "800002",
        })
      );
    });

    it("self-create with a joinCode that points to a DIFFERENT circle is denied", async () => {
      await seedCircle({
        circleID: "circle-A",
        joinCode: "900001",
        supervisor: { uid: "aunt1-uid", personID: "person-aunt1" },
      });
      await seedCircle({
        circleID: "circle-B",
        joinCode: "900002",
        supervisor: { uid: "auntB-uid", personID: "person-auntB" },
      });

      const attacker = "attacker-uid";
      const db = authedDb(attacker);
      // Attacker claims membership in B but provides A's joinCode.
      await assertFails(
        setDoc(doc(db, `userMemberships/${attacker}`), {
          careCircleID: "circle-B",
          personID: "attacker-person",
          role: "secondary_supervisor",
          joinedAt: new Date(),
          joinCode: "900001",
        })
      );
    });
  });

  // -- 9. Secondary supervisor: read access ------------------------------

  describe("secondary supervisor reads", () => {
    const circleID = "circle-secondary-read";
    const primary = { uid: "primary-uid", personID: "person-primary" };
    const secondary = { uid: "secondary-uid", personID: "person-secondary" };
    const grandpaMedID = "med-grandpa-secondary";

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "910001",
        supervisor: primary,
        extraSupervisors: [secondary],
        supervisorCount: 2,
      });
      await seedMedication(circleID, grandpaMedID, primary.personID);
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(
          doc(ctx.firestore(), `careCircles/${circleID}/familyContacts/dr-secondary`),
          { id: "dr-secondary", name: "Dr. S", phone: "+1-555-0101" }
        );
      });
    });

    it("can read the careCircle, people, medications, and familyContacts", async () => {
      const db = authedDb(secondary.uid);
      await assertSucceeds(getDoc(doc(db, `careCircles/${circleID}`)));
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/people/${primary.personID}`))
      );
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/medications/${grandpaMedID}`))
      );
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/familyContacts/dr-secondary`))
      );
    });
  });

  // -- 10. Secondary supervisor: write boundaries ------------------------

  describe("secondary supervisor writes", () => {
    const circleID = "circle-secondary-write";
    const primary = { uid: "primary-w-uid", personID: "person-primary-w" };
    const secondary = { uid: "secondary-w-uid", personID: "person-secondary-w" };
    const grandpa = { uid: "grandpa-w-uid", personID: "person-grandpa-w" };
    const grandpaMedID = "med-grandpa-w";

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "920001",
        supervisor: primary,
        extraSupervisors: [secondary],
        deviceClient: grandpa,
        supervisorCount: 2,
      });
      await seedMedication(circleID, grandpaMedID, grandpa.personID);
    });

    it("cannot create a medication", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/medications/sneaky-med`), {
          id: "sneaky-med",
          personID: grandpa.personID,
          name: "Sneaky",
          dose: "5mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 10,
          dateAdded: new Date(),
        })
      );
    });

    it("cannot update an existing medication", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        updateDoc(
          doc(db, `careCircles/${circleID}/medications/${grandpaMedID}`),
          { dose: "40mg" }
        )
      );
    });

    it("cannot delete a medication", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        deleteDoc(doc(db, `careCircles/${circleID}/medications/${grandpaMedID}`))
      );
    });

    it("cannot add a Person to the circle", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/people/sneaky-person`), {
          id: "sneaky-person",
          careCircleID: circleID,
          name: "Sneaky",
          role: "managed_client",
          languagePreference: "en",
          failedPinAttempts: 0,
        })
      );
    });

    it("cannot delete another Person", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        deleteDoc(doc(db, `careCircles/${circleID}/people/${grandpa.personID}`))
      );
    });

    it("cannot regenerate the join code (delete /joinCodes)", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(deleteDoc(doc(db, "joinCodes/920001")));
    });

    it("cannot rename the circle", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        updateDoc(doc(db, `careCircles/${circleID}`), { name: "Renamed Without Permission" })
      );
    });

    it("cannot create a doseLog", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/doseLogs/log-secondary-1`), {
          id: "log-secondary-1",
          medicationID: grandpaMedID,
          loggedByPersonID: secondary.personID,
          scheduledTime: new Date(),
          actualTime: new Date(),
          status: "taken",
        })
      );
    });
  });

  // -- 11. Alerts: tightened authority + acknowledgement model -----------
  //
  // Coordination model: any supervisor reads, any supervisor creates,
  // any supervisor acknowledges — but the acknowledgement is a single
  // atomic write that can only be made by the acting user, and once
  // landed, it can't be overwritten. Alerts are immutable history,
  // so no deletes outside the orphan-cleanup escape hatch.

  describe("alerts — tightened authority", () => {
    const circleID = "circle-alerts";
    const primary = { uid: "primary-a-uid", personID: "person-primary-a" };
    const secondary = { uid: "secondary-a-uid", personID: "person-secondary-a" };
    const stranger = { uid: "stranger-a-uid", personID: "person-stranger-a" };
    const grandpa = { uid: "grandpa-a-uid", personID: "person-grandpa-a" };

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "930001",
        supervisor: primary,
        extraSupervisors: [secondary],
        deviceClient: grandpa,
        supervisorCount: 2,
      });
    });

    it("a secondary supervisor can read alerts", async () => {
      const alertID = "alert-readable";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
        });
      });
      const db = authedDb(secondary.uid);
      await assertSucceeds(getDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`)));
    });

    it("a stranger CANNOT read alerts in someone else's circle", async () => {
      const alertID = "alert-private";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
        });
      });
      const db = authedDb(stranger.uid);
      await assertFails(getDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`)));
    });

    it("a supervisor can create a pending alert", async () => {
      const db = authedDb(secondary.uid);
      const alertID = "alert-fresh";
      await assertSucceeds(
        setDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID,
          type: "missedDose",
          personID: grandpa.personID,
          createdAt: serverTimestamp(),
          acknowledgedBy: null,
        })
      );
    });

    it("a create with acknowledgedBy already set is denied", async () => {
      const db = authedDb(secondary.uid);
      const alertID = "alert-presetacked";
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID,
          type: "missedDose",
          personID: grandpa.personID,
          createdAt: serverTimestamp(),
          acknowledgedBy: secondary.uid,  // pre-set ack — disallowed
          acknowledgedAt: new Date(),
        })
      );
    });

    it("a create with createdAt skewed away from request.time is denied", async () => {
      const db = authedDb(secondary.uid);
      const alertID = "alert-timeskew";
      // Plain `new Date()` doesn't equal request.time in the rules.
      await assertFails(
        setDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID,
          type: "missedDose",
          personID: grandpa.personID,
          createdAt: new Date(2020, 0, 1),
          acknowledgedBy: null,
        })
      );
    });

    it("a supervisor can acknowledge a pending alert as themselves", async () => {
      const alertID = "alert-to-ack";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
          acknowledgedBy: null,
        });
      });
      const db = authedDb(secondary.uid);
      await assertSucceeds(
        updateDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          acknowledgedBy: secondary.uid,
          acknowledgedAt: serverTimestamp(),
        })
      );
    });

    it("a supervisor CANNOT acknowledge as someone else", async () => {
      const alertID = "alert-spoof";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
          acknowledgedBy: null,
        });
      });
      const db = authedDb(secondary.uid);
      await assertFails(
        updateDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          acknowledgedBy: primary.uid,  // not the acting user
          acknowledgedAt: serverTimestamp(),
        })
      );
    });

    it("a supervisor CANNOT overwrite an existing acknowledgement", async () => {
      const alertID = "alert-already-acked";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
          acknowledgedBy: primary.uid,  // already ack'd by primary
          acknowledgedAt: new Date(),
        });
      });
      const db = authedDb(secondary.uid);
      await assertFails(
        updateDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          acknowledgedBy: secondary.uid,
          acknowledgedAt: serverTimestamp(),
        })
      );
    });

    it("a supervisor CANNOT change non-ack fields on an alert", async () => {
      const alertID = "alert-immutable";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
          acknowledgedBy: null,
        });
      });
      const db = authedDb(secondary.uid);
      await assertFails(
        updateDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          personID: primary.personID,  // not in the changed-keys allowlist
        })
      );
    });

    it("alerts cannot be deleted by any supervisor", async () => {
      const alertID = "alert-immortal";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
        });
      });
      const primaryDb = authedDb(primary.uid);
      await assertFails(deleteDoc(doc(primaryDb, `careCircles/${circleID}/alerts/${alertID}`)));
      const secondaryDb = authedDb(secondary.uid);
      await assertFails(deleteDoc(doc(secondaryDb, `careCircles/${circleID}/alerts/${alertID}`)));
    });

    // -- e1: first-write-wins across two supervisors -------------------
    //
    // Two supervisors on different devices both see the pending alert
    // and both tap Acknowledge within seconds. The first write lands
    // (the doc's acknowledgedBy flips from null to that uid); the
    // second write now sees a non-null acknowledgedBy and must be
    // rejected by the rules-layer "existing.acknowledgedBy == null"
    // predicate. This is the security-layer enforcement of the "first
    // to ack wins, second supervisor silently no-ops" promise that
    // `FirestoreService.acknowledgeAlert`'s transaction relies on.
    it("first-write-wins: a sequential second ack is rejected even by a different supervisor", async () => {
      const alertID = "alert-race";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
          acknowledgedBy: null,
        });
      });

      // First ack — secondary wins the race.
      const secondaryDb = authedDb(secondary.uid);
      await assertSucceeds(
        updateDoc(doc(secondaryDb, `careCircles/${circleID}/alerts/${alertID}`), {
          acknowledgedBy: secondary.uid,
          acknowledgedAt: serverTimestamp(),
        })
      );

      // Second ack — primary loses the race; the rule now sees a
      // non-null existing acknowledgedBy and must reject.
      const primaryDb = authedDb(primary.uid);
      await assertFails(
        updateDoc(doc(primaryDb, `careCircles/${circleID}/alerts/${alertID}`), {
          acknowledgedBy: primary.uid,
          acknowledgedAt: serverTimestamp(),
        })
      );
    });

    // -- e2: legacy "supervisor" role can still ack --------------------
    //
    // Pre-`PrimaryRoleMigration` data carries role="supervisor". The
    // `isAnySupervisor` helper in the rules treats that value as a
    // transitional alias for primary, so an in-flight upgrade where
    // one device has run the migration and another hasn't doesn't
    // strand the legacy user with a frozen ack button.
    it("a legacy 'supervisor' role can acknowledge a pending alert", async () => {
      const legacyCircleID = "circle-alerts-legacy";
      const legacy = { uid: "legacy-ack-uid", personID: "person-legacy-ack" };
      const target = { uid: "client-legacy-uid", personID: "person-client-legacy" };
      await seedCircle({
        circleID: legacyCircleID,
        joinCode: "930002",
        supervisor: legacy,
        deviceClient: target,
        legacyRoles: true,
      });
      const alertID = "alert-legacy";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${legacyCircleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: target.personID, createdAt: new Date(),
          acknowledgedBy: null,
        });
      });
      const db = authedDb(legacy.uid);
      await assertSucceeds(
        updateDoc(doc(db, `careCircles/${legacyCircleID}/alerts/${alertID}`), {
          acknowledgedBy: legacy.uid,
          acknowledgedAt: serverTimestamp(),
        })
      );
    });

    // -- e3: a device client cannot ack --------------------------------
    //
    // Device clients see their own dose list but never the supervisor
    // alerts feed in the UI; the rules layer enforces this regardless
    // of any future UI bug that surfaces the card to a client.
    it("a device client CANNOT acknowledge an alert", async () => {
      const alertID = "alert-client-ack";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: grandpa.personID, createdAt: new Date(),
          acknowledgedBy: null,
        });
      });
      const db = authedDb(grandpa.uid);
      await assertFails(
        updateDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          acknowledgedBy: grandpa.uid,
          acknowledgedAt: serverTimestamp(),
        })
      );
    });
  });

  // -- 11.5. Medical ID: per-person, supervisor read+write ----------------
  //
  // Path: /careCircles/{circleID}/people/{personID}/medicalID/{personID}.
  // Doc id must equal personID; both supervisor flavours can read and
  // edit; updatedAt must be `request.time`; delete is the
  // cascade-from-person-removal hatch only.

  describe("medical ID — per-person caregiver authority", () => {
    const circleID = "circle-medid";
    const primary = { uid: "primary-m-uid", personID: "person-primary-m" };
    const secondary = { uid: "secondary-m-uid", personID: "person-secondary-m" };
    const stranger = { uid: "stranger-m-uid", personID: "person-stranger-m" };
    const grandpa = { uid: "grandpa-m-uid", personID: "person-grandpa-m" };

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "950001",
        supervisor: primary,
        extraSupervisors: [secondary],
        deviceClient: grandpa,
        supervisorCount: 2,
      });
    });

    function medicalDocPath(personID: string): string {
      return `careCircles/${circleID}/people/${personID}/medicalID/${personID}`;
    }

    it("any supervisor can create a medical ID with doc id == personID", async () => {
      const db = authedDb(secondary.uid);
      await assertSucceeds(
        setDoc(doc(db, medicalDocPath(grandpa.personID)), {
          id: grandpa.personID,
          personID: grandpa.personID,
          allergies: ["Penicillin"],
          conditions: [],
          emergencyContacts: [],
          bloodType: "O+",
          notes: null,
          updatedAt: serverTimestamp(),
        })
      );
    });

    it("a stranger CANNOT read someone else's medical ID", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), medicalDocPath(grandpa.personID)), {
          id: grandpa.personID, personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: new Date(),
        });
      });
      const db = authedDb(stranger.uid);
      await assertFails(getDoc(doc(db, medicalDocPath(grandpa.personID))));
    });

    it("any supervisor can read", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), medicalDocPath(grandpa.personID)), {
          id: grandpa.personID, personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: new Date(),
        });
      });
      const secondaryDb = authedDb(secondary.uid);
      await assertSucceeds(getDoc(doc(secondaryDb, medicalDocPath(grandpa.personID))));
      const primaryDb = authedDb(primary.uid);
      await assertSucceeds(getDoc(doc(primaryDb, medicalDocPath(grandpa.personID))));
    });

    it("a create with doc id != personID is denied", async () => {
      const db = authedDb(secondary.uid);
      // Doc id at path is grandpa.personID but the payload claims a
      // different one — the rules enforce both match.
      await assertFails(
        setDoc(doc(db, medicalDocPath(grandpa.personID)), {
          id: "some-other-id",
          personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: serverTimestamp(),
        })
      );
    });

    it("a create with updatedAt skewed from request.time is denied", async () => {
      const db = authedDb(secondary.uid);
      await assertFails(
        setDoc(doc(db, medicalDocPath(grandpa.personID)), {
          id: grandpa.personID,
          personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: new Date(2020, 0, 1),   // not request.time
        })
      );
    });

    it("a supervisor can update an existing medical ID", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), medicalDocPath(grandpa.personID)), {
          id: grandpa.personID, personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: new Date(),
        });
      });
      const db = authedDb(secondary.uid);
      await assertSucceeds(
        setDoc(doc(db, medicalDocPath(grandpa.personID)), {
          id: grandpa.personID,
          personID: grandpa.personID,
          allergies: ["Aspirin"],
          conditions: ["Hypertension"],
          emergencyContacts: [],
          updatedAt: serverTimestamp(),
        })
      );
    });

    it("steady-state delete (parent Person still exists) is denied", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), medicalDocPath(grandpa.personID)), {
          id: grandpa.personID, personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: new Date(),
        });
      });
      const db = authedDb(secondary.uid);
      await assertFails(deleteDoc(doc(db, medicalDocPath(grandpa.personID))));
    });

    /// Regression for the shape the Swift `upsertMedicalID` actually
    /// puts on the wire after the May 13 rewrite — explicit-dict
    /// construction with optional fields omitted when nil. The rule
    /// must still pass with this shape; the previous Codable-encode-
    /// then-override pattern was suspected of leaving a transient
    /// `updatedAt: Date` mismatch.
    it("the explicit-dict Swift payload shape passes the create rule", async () => {
      const db = authedDb(secondary.uid);
      // Note: bloodType, dateOfBirth, and notes are all omitted —
      // matching the iOS code's conditional inclusion.
      await assertSucceeds(
        setDoc(doc(db, medicalDocPath(grandpa.personID)), {
          id: grandpa.personID,
          personID: grandpa.personID,
          allergies: [],
          conditions: [],
          emergencyContacts: [],
          updatedAt: serverTimestamp(),
        })
      );
    });

    it("cascade delete after Person is gone is permitted", async () => {
      // Seed the medical ID, then nuke the parent Person doc, then
      // try the delete. The rule's `!exists(parent)` should let the
      // delete through. Split into two `withSecurityRulesDisabled`
      // calls because a single callback doing both setDoc AND deleteDoc
      // on related paths tripped the "Firestore has already been
      // started" SDK error when the test then constructed a fresh
      // authenticatedContext — the symptom looked like a settings race
      // on the admin instance's lifecycle. Each admin call here
      // completes before the next starts.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), medicalDocPath(grandpa.personID)), {
          id: grandpa.personID, personID: grandpa.personID,
          allergies: [], conditions: [], emergencyContacts: [],
          updatedAt: new Date(),
        });
      });
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await deleteDoc(doc(ctx.firestore(),
          `careCircles/${circleID}/people/${grandpa.personID}`));
      });
      const db = authedDb(secondary.uid);
      await assertSucceeds(deleteDoc(doc(db, medicalDocPath(grandpa.personID))));
    });
  });

  // -- 12. promoteToPrimary: atomic role swap ----------------------------

  describe("promoteToPrimary atomic batch", () => {
    const circleID = "circle-promote";
    const primary = { uid: "primary-p-uid", personID: "person-primary-p" };
    const secondary = { uid: "secondary-p-uid", personID: "person-secondary-p" };

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: "940001",
        supervisor: primary,
        extraSupervisors: [secondary],
        supervisorCount: 2,
      });
    });

    /**
     * The exact write shape `applyPrimaryAssignment` produces:
     *   - update CareCircle.primarySupervisorPersonID
     *   - update old primary's Person doc role → secondary_supervisor
     *   - update new primary's Person doc role → primary_supervisor
     *   - update each /userMemberships/{uid}.role to match
     */
    function buildPromotionBatch(
      db: ReturnType<typeof authedDb>,
      circle: string,
      oldPrimary: SeedSupervisor,
      newPrimary: SeedSupervisor
    ) {
      const batch = writeBatch(db);
      batch.update(doc(db, `careCircles/${circle}`), {
        primarySupervisorPersonID: newPrimary.personID,
      });
      batch.update(doc(db, `careCircles/${circle}/people/${oldPrimary.personID}`), {
        role: "secondary_supervisor",
      });
      batch.update(doc(db, `careCircles/${circle}/people/${newPrimary.personID}`), {
        role: "primary_supervisor",
      });
      batch.update(doc(db, `userMemberships/${oldPrimary.uid}`), {
        role: "secondary_supervisor",
      });
      batch.update(doc(db, `userMemberships/${newPrimary.uid}`), {
        role: "primary_supervisor",
      });
      return batch;
    }

    it("the current primary can promote a secondary; roles atomically swap", async () => {
      const db = authedDb(primary.uid);
      const batch = buildPromotionBatch(db, circleID, primary, secondary);
      await assertSucceeds(batch.commit());

      // Verify the post-batch state under admin auth.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const adb = ctx.firestore();
        const circle = await getDoc(doc(adb, `careCircles/${circleID}`));
        const primaryDoc = await getDoc(
          doc(adb, `careCircles/${circleID}/people/${primary.personID}`)
        );
        const secondaryDoc = await getDoc(
          doc(adb, `careCircles/${circleID}/people/${secondary.personID}`)
        );
        if (
          circle.data()?.primarySupervisorPersonID !== secondary.personID ||
          primaryDoc.data()?.role !== "secondary_supervisor" ||
          secondaryDoc.data()?.role !== "primary_supervisor"
        ) {
          throw new Error("promotion did not produce expected post-state");
        }
      });
    });

    it("a secondary cannot promote themselves to primary", async () => {
      const db = authedDb(secondary.uid);
      const batch = buildPromotionBatch(db, circleID, primary, secondary);
      await assertFails(batch.commit());
    });

    it("after promotion, the demoted-to-secondary cannot write a medication", async () => {
      // First, perform the promotion as the current primary.
      const promoteDb = authedDb(primary.uid);
      const promote = buildPromotionBatch(promoteDb, circleID, primary, secondary);
      await assertSucceeds(promote.commit());

      // Now `primary` is a secondary. Their write must be denied.
      const demotedDb = authedDb(primary.uid);
      await assertFails(
        setDoc(doc(demotedDb, `careCircles/${circleID}/medications/post-demotion`), {
          id: "post-demotion",
          personID: primary.personID,
          name: "Should Fail",
          dose: "1mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 1,
          dateAdded: new Date(),
        })
      );
    });

    it("the new primary CAN write a medication after promotion", async () => {
      const promoteDb = authedDb(primary.uid);
      const promote = buildPromotionBatch(promoteDb, circleID, primary, secondary);
      await assertSucceeds(promote.commit());

      const newPrimaryDb = authedDb(secondary.uid);
      await assertSucceeds(
        setDoc(
          doc(newPrimaryDb, `careCircles/${circleID}/medications/post-promotion`),
          {
            id: "post-promotion",
            personID: secondary.personID,
            name: "Allowed",
            dose: "1mg",
            pillsPerDose: 1,
            foodRule: "either",
            currentSupply: 1,
            dateAdded: new Date(),
          }
        )
      );
    });

    // -- f1: missing target /userMemberships doc -----------------------
    //
    // Edge case from pre-`PrimaryRoleMigration` data: a supervisor's
    // Person doc exists but their `/userMemberships` doc was lost (or
    // never written by an early app version). The production
    // `applyPrimaryAssignment` uses `setData(merge: true)` for the
    // membership writes, but `buildPromotionBatch` mirrors the older
    // `updateData` shape — which fails at the SDK level when the doc
    // is absent. This pins that the "make sure to setData-merge or
    // PrimaryRoleMigration runs first" assumption is real: a naive
    // `update`-based promotion against legacy data refuses to commit.
    it("a buildPromotionBatch with an `update` against a missing target membership refuses to commit", async () => {
      // Delete target's membership AFTER beforeEach has seeded.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await deleteDoc(doc(ctx.firestore(), `userMemberships/${secondary.uid}`));
      });
      const db = authedDb(primary.uid);
      const batch = buildPromotionBatch(db, circleID, primary, secondary);
      await assertFails(batch.commit());
    });

    // -- f2: a secondary CANNOT promote a peer -------------------------
    //
    // The existing "secondary cannot self-promote" case is just one
    // shape of the same prohibition. This pins the rule that no
    // secondary, regardless of who the target is, can initiate the
    // promotion batch — `isPromotionBatch` reads `isPrimary(circleID)`
    // for the actor pre-batch and that returns false here.
    it("a secondary CANNOT promote a peer secondary to primary", async () => {
      const peerCircleID = "circle-promote-peer";
      const realPrimary = { uid: "real-primary-uid", personID: "person-real-primary" };
      const actorSecondary = { uid: "actor-sec-uid", personID: "person-actor-sec" };
      const targetSecondary = { uid: "target-sec-uid", personID: "person-target-sec" };
      await seedCircle({
        circleID: peerCircleID,
        joinCode: "940002",
        supervisor: realPrimary,
        extraSupervisors: [actorSecondary, targetSecondary],
        supervisorCount: 3,
      });
      const db = authedDb(actorSecondary.uid);
      const batch = buildPromotionBatch(db, peerCircleID, realPrimary, targetSecondary);
      await assertFails(batch.commit());
    });

    // -- f3: cross-circle promote ---------------------------------------
    //
    // The actor is primary of circle A; they try to promote a target
    // who is a supervisor of circle B. The Person doc path
    // (`careCircles/A/people/{targetID}`) doesn't exist for circle A's
    // target — both updates land against docs the actor has no
    // authority over. Rules reject before any write commits.
    it("a primary CANNOT promote a target whose Person doc lives in a different circle", async () => {
      const otherCircleID = "circle-promote-other";
      const otherPrimary = { uid: "other-primary-uid", personID: "person-other-primary" };
      const otherSecondary = { uid: "other-sec-uid", personID: "person-other-sec" };
      await seedCircle({
        circleID: otherCircleID,
        joinCode: "940003",
        supervisor: otherPrimary,
        extraSupervisors: [otherSecondary],
        supervisorCount: 2,
      });
      // Actor is primary of the original `circleID`. Target's Person
      // doc lives under `otherCircleID`. Wire up a batch that points
      // at the actor's own circle but names the foreign target.
      const db = authedDb(primary.uid);
      const batch = writeBatch(db);
      batch.update(doc(db, `careCircles/${circleID}`), {
        primarySupervisorPersonID: otherSecondary.personID,
      });
      // This Person doc does not exist under `circleID`.
      batch.update(
        doc(db, `careCircles/${circleID}/people/${otherSecondary.personID}`),
        { role: "primary_supervisor" }
      );
      batch.update(doc(db, `careCircles/${circleID}/people/${primary.personID}`), {
        role: "secondary_supervisor",
      });
      batch.update(doc(db, `userMemberships/${otherSecondary.uid}`), {
        role: "primary_supervisor",
      });
      batch.update(doc(db, `userMemberships/${primary.uid}`), {
        role: "secondary_supervisor",
      });
      await assertFails(batch.commit());
    });

    // -- g1: role transition + unrelated alert ack in the same batch ---
    //
    // The Step G concern: a single batch contains both the promote-
    // to-primary writes AND an ack on a completely separate alert
    // doc. Rules treat each write independently against its own
    // rule. The ack write evaluates `isAnySupervisor(circleID)` on
    // the actor's PRE-batch role (still primary at write time) and
    // passes; the promote writes pass via `isPromotionBatch`. The
    // batch commits.
    //
    // Documenting this in a test so a future reader doesn't try to
    // "tighten" the rules to require single-purpose batches — that
    // would break the legitimate UX case where a supervisor taps
    // Acknowledge while the promotion they kicked off is still
    // settling on the wire.
    it("a single batch with both a promotion AND an unrelated ack commits", async () => {
      const alertID = "alert-during-promotion";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: secondary.personID,
          createdAt: new Date(),
          acknowledgedBy: null,
        });
      });
      const db = authedDb(primary.uid);
      const batch = buildPromotionBatch(db, circleID, primary, secondary);
      // Tack the ack onto the same batch.
      batch.update(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
        acknowledgedBy: primary.uid,
        acknowledgedAt: serverTimestamp(),
      });
      await assertSucceeds(batch.commit());
    });
  });

  // -- 13. Legacy "supervisor" role is treated as primary -----------------

  describe("legacy supervisor role compatibility", () => {
    it("pre-migration data with role=supervisor is treated as primary for writes", async () => {
      const supervisor = { uid: "legacy-uid", personID: "person-legacy" };
      await seedCircle({
        circleID: "circle-legacy",
        joinCode: "950001",
        supervisor,
        legacyRoles: true,
      });
      const db = authedDb(supervisor.uid);
      await assertSucceeds(
        setDoc(doc(db, `careCircles/circle-legacy/medications/legacy-med`), {
          id: "legacy-med",
          personID: supervisor.personID,
          name: "Legacy",
          dose: "1mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 1,
          dateAdded: new Date(),
        })
      );
    });
  });

  // -- 14. Production scenario: Aunt 1 (founding supervisor) on the new ----
  //         rules, with pre-Prompt-18 data shape (role=supervisor on both
  //         the Person and /userMemberships docs, no primarySupervisorPersonID
  //         on the CareCircle yet). This is the exact state that broke
  //         production; the surrounding suite passed but didn't actually
  //         exercise this combination of read paths and the migration batch.

  describe("existing supervisor (pre-Prompt-18 production data)", () => {
    const circleID = "aunt1-circle";
    const aunt1 = { uid: "aunt1-uid", personID: "person-aunt1" };
    const joinCode = "987654";
    const grandpaMedID = "med-grandpa-1";

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode,
        supervisor: aunt1,
        legacyRoles: true, // role="supervisor" everywhere; no primarySupervisorPersonID
      });
      await seedMedication(circleID, grandpaMedID, aunt1.personID, "Lisinopril");
    });

    it("can read /careCircles/{id}", async () => {
      const db = authedDb(aunt1.uid);
      await assertSucceeds(getDoc(doc(db, `careCircles/${circleID}`)));
    });

    it("can read own /userMemberships doc", async () => {
      const db = authedDb(aunt1.uid);
      await assertSucceeds(getDoc(doc(db, `userMemberships/${aunt1.uid}`)));
    });

    it("can read /careCircles/{id}/people/{personID}", async () => {
      const db = authedDb(aunt1.uid);
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/people/${aunt1.personID}`))
      );
    });

    it("can read /careCircles/{id}/medications/{medID}", async () => {
      const db = authedDb(aunt1.uid);
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/medications/${grandpaMedID}`))
      );
    });

    it("can write a medication using legacy supervisor role", async () => {
      const db = authedDb(aunt1.uid);
      await assertSucceeds(
        setDoc(doc(db, `careCircles/${circleID}/medications/new-med`), {
          id: "new-med",
          personID: aunt1.personID,
          name: "Aspirin",
          dose: "81mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 30,
          dateAdded: new Date(),
        })
      );
    });

    /**
     * The migration batch shape produced by `applyPrimaryAssignment` for
     * a sole legacy supervisor: stamp `primarySupervisorPersonID`, flip
     * Person.role to `primary_supervisor`, mirror onto `/userMemberships`.
     * Three docs in one batch.
     */
    it("PrimaryRoleMigration batch is allowed (single-supervisor circle)", async () => {
      const db = authedDb(aunt1.uid);
      const batch = writeBatch(db);
      batch.update(doc(db, `careCircles/${circleID}`), {
        primarySupervisorPersonID: aunt1.personID,
      });
      batch.update(doc(db, `careCircles/${circleID}/people/${aunt1.personID}`), {
        role: "primary_supervisor",
      });
      batch.update(doc(db, `userMemberships/${aunt1.uid}`), {
        role: "primary_supervisor",
      });
      await assertSucceeds(batch.commit());
    });

    it("can write a medication AFTER migration completes", async () => {
      const db = authedDb(aunt1.uid);
      // Run the migration batch first.
      const migrate = writeBatch(db);
      migrate.update(doc(db, `careCircles/${circleID}`), {
        primarySupervisorPersonID: aunt1.personID,
      });
      migrate.update(doc(db, `careCircles/${circleID}/people/${aunt1.personID}`), {
        role: "primary_supervisor",
      });
      migrate.update(doc(db, `userMemberships/${aunt1.uid}`), {
        role: "primary_supervisor",
      });
      await migrate.commit();

      // Now write a new medication post-migration.
      await assertSucceeds(
        setDoc(doc(db, `careCircles/${circleID}/medications/post-mig-med`), {
          id: "post-mig-med",
          personID: aunt1.personID,
          name: "Atorvastatin",
          dose: "20mg",
          pillsPerDose: 1,
          foodRule: "either",
          currentSupply: 30,
          dateAdded: new Date(),
        })
      );
    });
  });

  // -- 15. The actual production breakage: legacy supervisor whose
  //         /userMemberships doc never made it to Firestore (or got lost).
  //         Without a membership doc, `memberOf(circleID)` returns false
  //         and ALL reads on the circle fail. The migration must be able
  //         to *create* the missing membership rather than only updating it.

  describe("legacy supervisor with missing /userMemberships doc", () => {
    const circleID = "broken-aunt-circle";
    const aunt = { uid: "broken-aunt-uid", personID: "person-broken-aunt" };
    const joinCode = "888888";

    beforeEach(async () => {
      // Seed the circle and Person doc directly under admin auth, but
      // INTENTIONALLY skip /userMemberships. This is the production
      // shape we suspect for the founding aunt: data uploaded by an
      // earlier migration that didn't write the membership index.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const db = ctx.firestore();
        await setDoc(doc(db, `careCircles/${circleID}`), {
          id: circleID,
          name: "Broken Family",
          joinCode,
          createdAt: new Date(),
          supervisorCount: 1,
          // No primarySupervisorPersonID — pre-Prompt-18.
        });
        await setDoc(doc(db, `joinCodes/${joinCode}`), {
          careCircleID: circleID,
          regeneratedAt: new Date(),
        });
        await setDoc(
          doc(db, `careCircles/${circleID}/people/${aunt.personID}`),
          {
            id: aunt.personID,
            careCircleID: circleID,
            name: "Aunt",
            role: "supervisor",
            languagePreference: "en",
            firebaseUID: aunt.uid,
            failedPinAttempts: 0,
          }
        );
        // /userMemberships intentionally not seeded.
      });
    });

    it("CANNOT read /careCircles without a membership doc — confirms the bug", async () => {
      const db = authedDb(aunt.uid);
      // Without /userMemberships, memberOf returns false and every read
      // on the circle fails. This matches the production "Missing or
      // insufficient permissions" symptom across careCircles, people,
      // medications, doseSchedules, doseLogs.
      await assertFails(getDoc(doc(db, `careCircles/${circleID}`)));
    });

    /**
     * The fix: the migration must be able to *create* the missing
     * membership doc, not just update it. The membership create rule's
     * branch (a) accepts a self-create when supervisorCount==0 (founder
     * bootstrap) — but the legacy circle has supervisorCount==1, so we
     * fall through to branch (c): primary onboarding another member.
     * For the legacy supervisor, isPrimary(circleID) reads Person.role
     * which is "supervisor" — the legacy alias counts as primary, so
     * the create succeeds.
     */
    it("legacy supervisor can self-create their own missing /userMemberships", async () => {
      const db = authedDb(aunt.uid);
      await assertSucceeds(
        setDoc(doc(db, `userMemberships/${aunt.uid}`), {
          careCircleID: circleID,
          personID: aunt.personID,
          role: "primary_supervisor",
          joinedAt: new Date(),
        })
      );
    });

    it("after backfilling /userMemberships, reads work again", async () => {
      const db = authedDb(aunt.uid);
      // Backfill the missing membership.
      await setDoc(doc(db, `userMemberships/${aunt.uid}`), {
        careCircleID: circleID,
        personID: aunt.personID,
        role: "primary_supervisor",
        joinedAt: new Date(),
      });
      // Now reads work.
      await assertSucceeds(getDoc(doc(db, `careCircles/${circleID}`)));
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${circleID}/people/${aunt.personID}`))
      );
    });

    /**
     * The migration runs in two phases when /userMemberships is missing:
     *   PHASE A: setData(merge:true) on the actor's /userMemberships,
     *            allowed by membership create rule branch (d) (the
     *            Person doc proves authority).
     *   PHASE B: the existing atomic batch (CareCircle update + Person
     *            updates + other /userMemberships updates). Now that
     *            PHASE A wrote /userMemberships, isPrimary resolves
     *            correctly for the actor and the batch's writes are
     *            authorised.
     *
     * They cannot fold into a single batch because the CareCircle and
     * Person update rules need isPrimary, which depends on a pre-batch
     * /userMemberships. Adding isPrimaryAfter to Person update would
     * let a secondary supervisor self-promote in one batch — explicitly
     * a security hole. The two-phase split avoids that.
     */
    it("PHASE A: actor self-backfills /userMemberships via setData(merge: true)", async () => {
      const db = authedDb(aunt.uid);
      await assertSucceeds(
        setDoc(
          doc(db, `userMemberships/${aunt.uid}`),
          {
            careCircleID: circleID,
            personID: aunt.personID,
            role: "primary_supervisor",
            joinedAt: serverTimestamp(),
          },
          { merge: true }
        )
      );
    });

    it("PHASE B: the atomic role-assignment batch succeeds after PHASE A", async () => {
      const db = authedDb(aunt.uid);
      // PHASE A: ensure /userMemberships exists.
      await setDoc(
        doc(db, `userMemberships/${aunt.uid}`),
        {
          careCircleID: circleID,
          personID: aunt.personID,
          role: "primary_supervisor",
          joinedAt: serverTimestamp(),
        },
        { merge: true }
      );

      // PHASE B: the existing atomic batch.
      const batch = writeBatch(db);
      batch.update(doc(db, `careCircles/${circleID}`), {
        primarySupervisorPersonID: aunt.personID,
      });
      batch.update(doc(db, `careCircles/${circleID}/people/${aunt.personID}`), {
        role: "primary_supervisor",
      });
      batch.set(
        doc(db, `userMemberships/${aunt.uid}`),
        { role: "primary_supervisor" },
        { merge: true }
      );
      await assertSucceeds(batch.commit());
    });

    it("a SECONDARY cannot self-promote by writing their own /userMemberships role", async () => {
      // Defense in depth: even if a secondary uses the membership
      // self-edit / branch-(d) path to bump their /userMemberships role
      // to "primary_supervisor", the rules read role from the Person
      // doc, not the membership. They still cannot update Person.role
      // because the Person update rule's isPrimary check fails.
      const secondary = { uid: "secondary-uid-x", personID: "person-secondary-x" };
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const db = ctx.firestore();
        // Seed: secondary has both Person + /userMemberships with role=secondary_supervisor.
        await setDoc(
          doc(db, `careCircles/${circleID}/people/${secondary.personID}`),
          {
            id: secondary.personID,
            careCircleID: circleID,
            name: "Secondary",
            role: "secondary_supervisor",
            languagePreference: "en",
            firebaseUID: secondary.uid,
            failedPinAttempts: 0,
          }
        );
        await setDoc(doc(db, `userMemberships/${secondary.uid}`), {
          careCircleID: circleID,
          personID: secondary.personID,
          role: "secondary_supervisor",
          joinedAt: new Date(),
        });
      });

      const db = authedDb(secondary.uid);
      // Step 1: secondary "promotes" their /userMemberships role —
      // allowed (it's informational), but doesn't change anything that
      // the rules trust.
      await assertSucceeds(
        updateDoc(doc(db, `userMemberships/${secondary.uid}`), {
          role: "primary_supervisor",
        })
      );
      // Step 2: secondary tries to update Person.role to primary —
      // DENIED. The rules read role from the Person doc, which is still
      // "secondary_supervisor". isPrimary fails.
      await assertFails(
        updateDoc(
          doc(db, `careCircles/${circleID}/people/${secondary.personID}`),
          { role: "primary_supervisor" }
        )
      );
    });
  });

  // -- 15.5. Joiner bootstrap: atomic 3-write batch ---------------------
  //
  // The joining secondary supervisor needs to land three writes atomically:
  //   a) /userMemberships/{uid} create with the joinCode proof,
  //   b) /careCircles/{id}/people/{newPersonID} create as secondary,
  //   c) /careCircles/{id}.supervisorCount += 1.
  // The careCircle update rule's joiner-bootstrap branch (d) recognises
  // (c) when (a) lands in the same batch with careCircleID matching.

  describe("joiner bootstrap (atomic 3-write batch)", () => {
    const circleID = "circle-joiner-bootstrap";
    const primary = { uid: "primary-bootstrap-uid", personID: "person-primary-bs" };
    const joiner = { uid: "joiner-bootstrap-uid", personID: "person-joiner-bs" };
    const code = "550000";

    beforeEach(async () => {
      await seedCircle({
        circleID,
        joinCode: code,
        supervisor: primary,
        supervisorCount: 1,
      });
    });

    it("joiner can land /userMemberships + Person + supervisorCount++ in one batch", async () => {
      const db = authedDb(joiner.uid);
      const batch = writeBatch(db);
      batch.set(doc(db, `userMemberships/${joiner.uid}`), {
        careCircleID: circleID,
        personID: joiner.personID,
        role: "secondary_supervisor",
        joinedAt: new Date(),
        joinCode: code,
      });
      batch.set(doc(db, `careCircles/${circleID}/people/${joiner.personID}`), {
        id: joiner.personID,
        careCircleID: circleID,
        name: "New Joiner",
        role: "secondary_supervisor",
        languagePreference: "en",
        firebaseUID: joiner.uid,
        failedPinAttempts: 0,
      });
      batch.update(doc(db, `careCircles/${circleID}`), {
        supervisorCount: 2,
      });
      await assertSucceeds(batch.commit());
    });

    it("incrementing supervisorCount WITHOUT writing /userMemberships in the same batch is denied", async () => {
      // No membership doc lands in this batch — joiner branch fails
      // because the existsAfter(/userMemberships/{auth.uid}) check
      // returns false. The other branches (isPrimary, decrement, etc.)
      // also don't apply. Should be rejected.
      const db = authedDb(joiner.uid);
      await assertFails(
        updateDoc(doc(db, `careCircles/${circleID}`), {
          supervisorCount: 2,
        })
      );
    });

    it("incrementing supervisorCount by MORE THAN 1 in a joiner batch is denied", async () => {
      const db = authedDb(joiner.uid);
      const batch = writeBatch(db);
      batch.set(doc(db, `userMemberships/${joiner.uid}`), {
        careCircleID: circleID,
        personID: joiner.personID,
        role: "secondary_supervisor",
        joinedAt: new Date(),
        joinCode: code,
      });
      batch.set(doc(db, `careCircles/${circleID}/people/${joiner.personID}`), {
        id: joiner.personID,
        careCircleID: circleID,
        name: "Greedy",
        role: "secondary_supervisor",
        languagePreference: "en",
        firebaseUID: joiner.uid,
        failedPinAttempts: 0,
      });
      batch.update(doc(db, `careCircles/${circleID}`), {
        supervisorCount: 5,  // not + 1
      });
      await assertFails(batch.commit());
    });

    it("a joiner whose /userMemberships in the batch points at a DIFFERENT circle cannot increment this circle's count", async () => {
      // Membership claims circle-other (not seeded — but exists check
      // doesn't apply here; the joinCode validation is what matters).
      // The careCircle update rule's joiner branch verifies the
      // /userMemberships's careCircleID equals the circle being
      // updated, so this batch must fail.
      await seedCircle({
        circleID: "circle-other",
        joinCode: "550001",
        supervisor: { uid: "other-uid", personID: "person-other" },
      });
      const db = authedDb(joiner.uid);
      const batch = writeBatch(db);
      batch.set(doc(db, `userMemberships/${joiner.uid}`), {
        careCircleID: "circle-other",
        personID: joiner.personID,
        role: "secondary_supervisor",
        joinedAt: new Date(),
        joinCode: "550001",
      });
      batch.update(doc(db, `careCircles/${circleID}`), {
        supervisorCount: 2,
      });
      await assertFails(batch.commit());
    });
  });

  // -- 16. Orphan-founder cleanup --------------------------------------
  //
  // Rules-layer support for `OrphanCircleCleanupMigration`. The founder
  // of an orphan circle (their Person doc is the careCircle's
  // primarySupervisorPersonID and has firebaseUID == auth.uid) must be
  // able to read the orphan, delete its subcollections, delete the
  // /joinCodes doc, and delete the careCircle root — even though their
  // /userMemberships points at a different (real) circle.

  describe("orphan-founder cleanup", () => {
    const realCircleID = "real-circle";
    const orphanCircleID = "orphan-circle";
    const founder = { uid: "founder-uid", personID: "person-founder" };
    const stranger = { uid: "stranger-uid", personID: "person-stranger" };

    beforeEach(async () => {
      // Real circle: founder is the active primary, has /userMemberships.
      await seedCircle({
        circleID: realCircleID,
        joinCode: "111111",
        supervisor: founder,
      });
      // Orphan circle: founder's Person doc is the primary, but
      // /userMemberships points at the real circle (founder is keyed by
      // uid in /userMemberships and so cannot be the membership of two
      // circles). We seed the orphan's Person doc directly without
      // touching /userMemberships.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const db = ctx.firestore();
        await setDoc(doc(db, `careCircles/${orphanCircleID}`), {
          id: orphanCircleID,
          name: "Orphan Family",
          joinCode: "999999",
          createdAt: new Date(),
          supervisorCount: 1,
          primarySupervisorPersonID: founder.personID,
        });
        await setDoc(doc(db, `joinCodes/999999`), {
          careCircleID: orphanCircleID,
          regeneratedAt: new Date(),
        });
        await setDoc(
          doc(db, `careCircles/${orphanCircleID}/people/${founder.personID}`),
          {
            id: founder.personID,
            careCircleID: orphanCircleID,
            name: "Founder",
            role: "primary_supervisor",
            languagePreference: "en",
            firebaseUID: founder.uid,
            failedPinAttempts: 0,
          }
        );
        // A stale medication so we can verify subcollection delete.
        await setDoc(
          doc(db, `careCircles/${orphanCircleID}/medications/orphan-med`),
          {
            id: "orphan-med",
            personID: founder.personID,
            name: "Stale",
            dose: "5mg",
            pillsPerDose: 1,
            foodRule: "either",
            currentSupply: 30,
            dateAdded: new Date(),
          }
        );
      });
    });

    it("founder can READ the orphan careCircle even without /userMemberships pointing at it", async () => {
      const db = authedDb(founder.uid);
      await assertSucceeds(getDoc(doc(db, `careCircles/${orphanCircleID}`)));
    });

    it("a stranger CANNOT read the orphan careCircle", async () => {
      const db = authedDb(stranger.uid);
      await assertFails(getDoc(doc(db, `careCircles/${orphanCircleID}`)));
    });

    it("founder can read and DELETE a Person doc in the orphan", async () => {
      const db = authedDb(founder.uid);
      await assertSucceeds(
        getDoc(doc(db, `careCircles/${orphanCircleID}/people/${founder.personID}`))
      );
      await assertSucceeds(
        deleteDoc(doc(db, `careCircles/${orphanCircleID}/people/${founder.personID}`))
      );
    });

    it("founder can DELETE a medication in the orphan circle", async () => {
      const db = authedDb(founder.uid);
      await assertSucceeds(
        deleteDoc(doc(db, `careCircles/${orphanCircleID}/medications/orphan-med`))
      );
    });

    it("founder can DELETE the /joinCodes doc pointing at the orphan", async () => {
      const db = authedDb(founder.uid);
      await assertSucceeds(deleteDoc(doc(db, `joinCodes/999999`)));
    });

    it("a stranger CANNOT delete the /joinCodes doc pointing at the orphan", async () => {
      const db = authedDb(stranger.uid);
      await assertFails(deleteDoc(doc(db, `joinCodes/999999`)));
    });

    it("founder can DELETE the orphan careCircle root", async () => {
      const db = authedDb(founder.uid);
      await assertSucceeds(deleteDoc(doc(db, `careCircles/${orphanCircleID}`)));
    });

    it("a stranger CANNOT delete the orphan careCircle even though it has no membership", async () => {
      const db = authedDb(stranger.uid);
      await assertFails(deleteDoc(doc(db, `careCircles/${orphanCircleID}`)));
    });

    it("isOrphanFounder does NOT grant the founder rights on someone else's circle", async () => {
      // Stranger's circle, stranger is the primary. Founder has nothing
      // to do with it.
      await seedCircle({
        circleID: "strangers-circle",
        joinCode: "222222",
        supervisor: stranger,
      });
      const db = authedDb(founder.uid);
      await assertFails(getDoc(doc(db, `careCircles/strangers-circle`)));
      await assertFails(deleteDoc(doc(db, `careCircles/strangers-circle`)));
    });

    // -- Positive coverage: helper returns true with NO membership row -----
    //
    // The two existing orphan-founder cleanup shapes assume the user
    // has a `/userMemberships` row pointing at their REAL circle (the
    // production case after `OrphanCircleCleanupMigration` runs). This
    // test covers the other absence shape: the user has no
    // `/userMemberships` row at all, but their Person doc still
    // records them as the orphan's primary. Could arise from a wipe of
    // /userMemberships or a never-written index doc on early app
    // versions. The tightened helper's `!exists(membership)` branch
    // is what permits this; without that conjunct the helper would
    // still return true here too, but the test pins the explicit
    // membership-absent shape so a future "let's simplify" rewrite
    // can't drop the branch.
    it("isOrphanFounder is true when the founder has NO /userMemberships row anywhere", async () => {
      // Tear down the founder's /userMemberships pointing at realCircleID
      // so they have no membership at all. Person docs in both circles
      // remain intact.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await deleteDoc(doc(ctx.firestore(), `userMemberships/${founder.uid}`));
      });
      const db = authedDb(founder.uid);
      // Read on the orphan circle is gated on `memberOf(circleID) ||
      // isOrphanFounder(circleID)`. memberOf is now false (no
      // membership), so the read passes iff the helper returns true.
      await assertSucceeds(getDoc(doc(db, `careCircles/${orphanCircleID}`)));
      // Same for the delete — the careCircle root delete rule's
      // `isOrphanFounder` branch carries the entire weight when
      // `isPrimary` is false.
      await assertSucceeds(deleteDoc(doc(db, `careCircles/${orphanCircleID}`)));
    });

    // -- Negative coverage: helper is FALSE in steady-state primary case ---
    //
    // This is the regression that motivated the May 28 tightening. The
    // pre-fix helper returned true for any healthy primary because it
    // only checked the founder anchor — and the founder anchor is
    // always satisfied by a current primary as a side effect of being
    // primary. The three rules-test failures named in the May 27
    // build_log "Discovered but not fixed" section all traced to this.
    // The explicit assertion here pins the contract so a future rewrite
    // can't reintroduce the over-permissive shape without this test
    // catching it.
    it("isOrphanFounder is false for a healthy primary of their own circle", async () => {
      // realCircleID has the founder as primary with a /userMemberships
      // pointing at realCircleID — exactly the steady-state shape that
      // was previously over-permissive.
      const db = authedDb(founder.uid);

      // The alerts delete rule is `allow delete: if isOrphanFounder(circleID)`
      // with no other branch — the cleanest single-clause probe. If the
      // helper is over-permissive, this delete succeeds; tightened, it
      // fails.
      const alertID = "alert-isPrimary-cannot-delete";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${realCircleID}/alerts/${alertID}`), {
          id: alertID, type: "missedDose",
          personID: founder.personID, createdAt: new Date(),
        });
      });
      await assertFails(deleteDoc(doc(db, `careCircles/${realCircleID}/alerts/${alertID}`)));
    });
  });
});

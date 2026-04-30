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

  // -- 11. Alerts: secondary supervisor authority ------------------------

  describe("alerts — secondary write authority", () => {
    const circleID = "circle-alerts";
    const primary = { uid: "primary-a-uid", personID: "person-primary-a" };
    const secondary = { uid: "secondary-a-uid", personID: "person-secondary-a" };
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

    it("a secondary supervisor can create an alert", async () => {
      const db = authedDb(secondary.uid);
      const alertID = "alert-from-secondary";
      await assertSucceeds(
        setDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID,
          personID: grandpa.personID,
          kind: "missed_dose",
          message: "Grandpa missed morning Lipitor",
          createdAt: new Date(),
        })
      );
    });

    it("a secondary supervisor can acknowledge any alert in the circle", async () => {
      const alertID = "alert-to-ack";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID,
          personID: grandpa.personID,
          kind: "missed_dose",
          message: "test",
          createdAt: new Date(),
        });
      });
      const db = authedDb(secondary.uid);
      await assertSucceeds(
        updateDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`), {
          resolvedAt: new Date(),
        })
      );
    });

    it("a secondary supervisor cannot delete an alert", async () => {
      const alertID = "alert-to-delete";
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `careCircles/${circleID}/alerts/${alertID}`), {
          id: alertID,
          personID: grandpa.personID,
          kind: "missed_dose",
          message: "test",
          createdAt: new Date(),
        });
      });
      const db = authedDb(secondary.uid);
      await assertFails(
        deleteDoc(doc(db, `careCircles/${circleID}/alerts/${alertID}`))
      );
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
});

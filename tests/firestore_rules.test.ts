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
 */
async function seedCircle(opts: {
  circleID: string;
  joinCode: string;
  supervisor: SeedSupervisor;
  deviceClient?: SeedDeviceClient;
  supervisorCount?: number;
  extraSupervisors?: SeedSupervisor[];
}): Promise<SeededCircle> {
  const supervisorCount = opts.supervisorCount ?? 1;
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `careCircles/${opts.circleID}`), {
      id: opts.circleID,
      name: "Test Family",
      joinCode: opts.joinCode,
      createdAt: new Date(),
      supervisorCount,
    });
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
        role: "supervisor",
        languagePreference: "en",
        firebaseUID: opts.supervisor.uid,
        failedPinAttempts: 0,
      }
    );
    await setDoc(doc(db, `userMemberships/${opts.supervisor.uid}`), {
      careCircleID: opts.circleID,
      personID: opts.supervisor.personID,
      role: "supervisor",
      joinedAt: new Date(),
    });

    for (const sup of opts.extraSupervisors ?? []) {
      await setDoc(doc(db, `careCircles/${opts.circleID}/people/${sup.personID}`), {
        id: sup.personID,
        careCircleID: opts.circleID,
        name: "Co-Supervisor",
        role: "supervisor",
        languagePreference: "en",
        firebaseUID: sup.uid,
        failedPinAttempts: 0,
      });
      await setDoc(doc(db, `userMemberships/${sup.uid}`), {
        careCircleID: opts.circleID,
        personID: sup.personID,
        role: "supervisor",
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

    it("allows a supervisor to leave when at least one other remains", async () => {
      const supervisor = { uid: "aunt1-uid", personID: "person-aunt1" };
      const coSup = { uid: "aunt2-uid", personID: "person-aunt2" };
      const seeded = await seedCircle({
        circleID: "circle-pair",
        joinCode: "500002",
        supervisor,
        extraSupervisors: [coSup],
        supervisorCount: 2,
      });

      // Aunt 1 leaves: batch { delete Person, decrement count, delete /userMemberships }.
      const db = authedDb(supervisor.uid);
      const batch = writeBatch(db);
      batch.delete(doc(db, `careCircles/${seeded.circleID}/people/${supervisor.personID}`));
      batch.update(doc(db, `careCircles/${seeded.circleID}`), { supervisorCount: 1 });
      batch.delete(doc(db, `userMemberships/${supervisor.uid}`));
      await assertSucceeds(batch.commit());
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
          role: "supervisor",
          joinedAt: new Date(),
          joinCode: "900001",
        })
      );
    });
  });
});

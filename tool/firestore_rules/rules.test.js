// Security-rules tests for ../../firestore.rules (local-first table night),
// against the LOCAL Firestore emulator. Run ./run.sh.
//
// Cast: o = organizer, a / b = players who scanned the QR, x = signed in
// but holding a wrong secret, anon = not signed in.

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs,
  serverTimestamp, setLogLevel, Timestamp,
} = require('firebase/firestore');

setLogLevel('silent');

const PROJECT = 'demo-feltnotes';
const NIGHT = 'ABCD2345';
const SECRET = 'WXYZ6789';
const N = `nights/${NIGHT}`;
const DEV = { o: 'SAGEPHN23456', a: 'AMYPHNE23456', b: 'BRYPHNE23456', x: 'XAVPHNE23456' };

let passed = 0;
async function test(name, fn) {
  try {
    await fn();
  } catch (e) {
    console.error(`  FAIL - ${name}`);
    throw e;
  }
  passed++;
  console.log(`  ok - ${name}`);
}

(async () => {
  const env = await initializeTestEnvironment({
    projectId: PROJECT,
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
      host: '127.0.0.1',
      port: 8012,
    },
  });
  const db = (uid) => env.authenticatedContext(uid).firestore();
  const o = db('o'), a = db('a'), b = db('b'), x = db('x');
  const anon = env.unauthenticatedContext().firestore();

  const days = (d) => Timestamp.fromMillis(Date.now() + d * 86400000);
  const night = (over = {}) => ({
    secret: SECRET, organizer: 'Sage', createdAt: serverTimestamp(), expireAt: days(60), ...over,
  });
  const member = (uid, over = {}) => ({
    name: uid.toUpperCase(), deviceId: DEV[uid], secret: SECRET, joinedAt: serverTimestamp(), expireAt: days(60),
    ...over,
  });
  const ev = (n) => Array.from({ length: n }, (_, i) => JSON.stringify({ s: i + 1, k: 'play', t: 1000 + i }));
  const log = (uid, part, count, over = {}) => ({
    uid, deviceId: DEV[uid], part, count, events: ev(count), name: uid.toUpperCase(),
    clientMs: 1793404800000, updatedAt: serverTimestamp(), expireAt: days(60), ...over,
  });
  const logPath = (uid, part) => `${N}/logs/${DEV[uid]}_${part}`;
  const cards = (uid, e, c, over = {}) => ({
    uid, deviceId: DEV[uid], e, c, at: serverTimestamp(), expireAt: days(60), ...over,
  });
  const cardPath = (uid, e) => `${N}/cards/${DEV[uid]}_${e}`;

  console.log('night');
  await test('a non-member may learn a night does not exist yet', () =>
    assertSucceeds(getDoc(doc(a, N))));
  await test('not signed in: nothing', () => assertFails(getDoc(doc(anon, N))));
  await test('night id must be 8 chars from the unambiguous alphabet', () =>
    assertFails(setDoc(doc(a, 'nights/ABCD234O'), night())));
  await test('secret must be 8 chars from the alphabet', () =>
    assertFails(setDoc(doc(a, 'nights/QQQQ2222'), night({ secret: 'short' }))));
  await test('unknown fields rejected', () =>
    assertFails(setDoc(doc(a, 'nights/QQQQ3333'), night({ admin: 'a' }))));
  await test('createdAt must be server time', () =>
    assertFails(setDoc(doc(a, 'nights/QQQQ4444'), night({ createdAt: 5 }))));
  await test('expireAt is required', () => {
    const { expireAt, ...noExpiry } = night();
    return assertFails(setDoc(doc(a, 'nights/QQQQ5555'), noExpiry));
  });
  await test('expireAt must be 1 to 90 days ahead (no keeping data forever)', async () => {
    await assertFails(setDoc(doc(a, 'nights/QQQQ6666'), night({ expireAt: days(400) })));
    await assertFails(setDoc(doc(a, 'nights/QQQQ6666'), night({ expireAt: days(0.5) })));
  });
  await test('the first phone online (a player, not the organizer) creates the night', () =>
    assertSucceeds(setDoc(doc(a, N), night())));
  await test('nobody can overwrite the night (secret is fixed)', () =>
    assertFails(setDoc(doc(x, N), night({ secret: 'QQQQQQQQ' }))));
  await test('nobody can update the night', () =>
    assertFails(updateDoc(doc(a, N), { organizer: 'Mallory' })));
  await test('nobody can delete the night', () => assertFails(deleteDoc(doc(a, N))));
  await test('a non-member cannot read an existing night', () => assertFails(getDoc(doc(x, N))));
  await test('nobody lists nights', () => assertFails(getDocs(collection(a, 'nights'))));

  console.log('members');
  await test('a joins with the secret', () => assertSucceeds(setDoc(doc(a, `${N}/members/a`), member('a'))));
  await test('o joins later from home', () => assertSucceeds(setDoc(doc(o, `${N}/members/o`), member('o'))));
  await test('b joins', () => assertSucceeds(setDoc(doc(b, `${N}/members/b`), member('b'))));
  await test('wrong secret is refused', () =>
    assertFails(setDoc(doc(x, `${N}/members/x`), member('x', { secret: 'QQQQQQQQ' }))));
  await test('cannot create a member doc for another uid', () =>
    assertFails(setDoc(doc(x, `${N}/members/zz`), member('x'))));
  await test('joining a night that does not exist is refused', () =>
    assertFails(setDoc(doc(a, 'nights/ZZZZ9999/members/a'), member('a'))));
  await test('device id must look like one', () =>
    assertFails(setDoc(doc(x, `${N}/members/x`), member('x', { deviceId: 'abc' }))));
  await test('name 1..24 chars', () =>
    assertFails(setDoc(doc(x, `${N}/members/x`), member('x', { name: '' }))));
  await test('re-join may rename', () =>
    assertSucceeds(setDoc(doc(a, `${N}/members/a`), member('a', { name: 'Amy' }))));
  await test('re-join may not change the device id', () =>
    assertFails(setDoc(doc(a, `${N}/members/a`), member('a', { deviceId: DEV.b }))));
  await test('members read the night and the member list', async () => {
    await assertSucceeds(getDoc(doc(b, N)));
    await assertSucceeds(getDocs(collection(b, `${N}/members`)));
  });
  await test('non-members cannot read members', () =>
    assertFails(getDocs(collection(x, `${N}/members`))));
  await test('members cannot be deleted', () => assertFails(deleteDoc(doc(a, `${N}/members/a`))));

  console.log('logs');
  await test('a uploads its first part', () => assertSucceeds(setDoc(doc(a, logPath('a', 0)), log('a', 0, 3))));
  await test('a re-uploads the same part (idempotent)', () =>
    assertSucceeds(setDoc(doc(a, logPath('a', 0)), log('a', 0, 3))));
  await test('a appends (count grows) with a measured skew', () =>
    assertSucceeds(setDoc(doc(a, logPath('a', 0)), log('a', 0, 5, { skew: -1234 }))));
  await test('a part never shrinks (stale upload cannot erase)', () =>
    assertFails(setDoc(doc(a, logPath('a', 0)), log('a', 0, 4))));
  await test('count must match the events list', () =>
    assertFails(setDoc(doc(a, logPath('a', 1)), log('a', 1, 2, { count: 9 }))));
  await test('at most 400 events per part', () =>
    assertFails(setDoc(doc(a, logPath('a', 1)), log('a', 1, 401))));
  await test('400 events is fine', () => assertSucceeds(setDoc(doc(a, logPath('a', 1)), log('a', 1, 400))));
  await test('doc id must be deviceId_part', () =>
    assertFails(setDoc(doc(a, `${N}/logs/${DEV.a}_7`), log('a', 2, 1))));
  await test('cannot write under another device id', () =>
    assertFails(setDoc(doc(a, logPath('b', 0)), log('a', 0, 1, { deviceId: DEV.b }))));
  await test("cannot overwrite another member's log", () =>
    assertFails(setDoc(doc(b, logPath('a', 0)), log('b', 0, 9, { deviceId: DEV.a }))));
  await test('uid must be me', () =>
    assertFails(setDoc(doc(b, logPath('b', 0)), log('b', 0, 1, { uid: 'a' }))));
  await test('updatedAt must be server time', () =>
    assertFails(setDoc(doc(b, logPath('b', 0)), log('b', 0, 1, { updatedAt: 5 }))));
  await test('skew must be an int', () =>
    assertFails(setDoc(doc(b, logPath('b', 0)), log('b', 0, 1, { skew: 'x' }))));
  await test('unknown fields rejected', () =>
    assertFails(setDoc(doc(b, logPath('b', 0)), log('b', 0, 1, { cardsOfEveryone: [] }))));
  await test('non-member cannot upload', () =>
    assertFails(setDoc(doc(x, logPath('x', 0)), log('x', 0, 1))));
  await test('b and o upload', async () => {
    await assertSucceeds(setDoc(doc(b, logPath('b', 0)), log('b', 0, 2)));
    await assertSucceeds(setDoc(doc(o, logPath('o', 0)), log('o', 0, 120)));
  });
  await test("the organizer's TV reads every log", async () => {
    const q = await assertSucceeds(getDocs(collection(o, `${N}/logs`)));
    if (q.size !== 4) throw new Error(`expected 4 log docs, got ${q.size}`);
  });
  await test('non-members cannot read logs', () => assertFails(getDocs(collection(x, `${N}/logs`))));
  await test('not signed in cannot read logs', () => assertFails(getDocs(collection(anon, `${N}/logs`))));
  await test("nobody deletes another member's log", () => assertFails(deleteDoc(doc(b, logPath('a', 1)))));
  await test('non-members cannot delete logs', () => assertFails(deleteDoc(doc(x, logPath('a', 1)))));
  await test('the owner takes its log back (sharing off), then writes the short one', async () => {
    await assertSucceeds(deleteDoc(doc(a, logPath('a', 1))));
    await assertSucceeds(deleteDoc(doc(a, logPath('a', 0))));
    await assertSucceeds(setDoc(doc(a, logPath('a', 0)), log('a', 0, 2)));
  });
  await test('deleting a log that is already gone is a harmless no-op', () =>
    assertSucceeds(deleteDoc(doc(a, logPath('a', 9)))));
  await test('log expireAt must be 1 to 90 days ahead', () =>
    assertFails(setDoc(doc(b, logPath('b', 0)), log('b', 0, 3, { expireAt: days(365) }))));

  console.log('cards');
  await test('a writes its cards for entry 3 once the hand is over', () =>
    assertSucceeds(setDoc(doc(a, cardPath('a', 3)), cards('a', 3, [51, 50]))));
  await test('nobody, not even a member, reads them for 2 minutes', async () => {
    await assertFails(getDoc(doc(b, cardPath('a', 3))));
    await assertFails(getDoc(doc(o, cardPath('a', 3))));
    await assertFails(getDoc(doc(a, cardPath('a', 3))));
  });
  await test('cards cannot be listed (no "watch everyone\'s cards")', () =>
    assertFails(getDocs(collection(o, `${N}/cards`))));
  await test('after the hold, members read them one document at a time', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), cardPath('b', 4)), cards('b', 4, [0, 13], {
        at: Timestamp.fromMillis(Date.now() - 3 * 60000),
      }));
    });
    await assertSucceeds(getDoc(doc(o, cardPath('b', 4))));
    await assertSucceeds(getDoc(doc(a, cardPath('b', 4))));
  });
  await test('non-members never read cards, even old ones', async () => {
    await assertFails(getDoc(doc(x, cardPath('b', 4))));
    await assertFails(getDoc(doc(anon, cardPath('b', 4))));
  });
  await test('a missing card document reads as refused (not "does not exist")', () =>
    assertFails(getDoc(doc(o, cardPath('b', 99)))));
  await test('at must be server time (cannot back-date to dodge the hold)', () =>
    assertFails(setDoc(doc(a, cardPath('a', 5)), cards('a', 5, [1, 2], { at: Timestamp.fromMillis(Date.now() - 600000) }))));
  await test('two cards, each 0..51', async () => {
    await assertFails(setDoc(doc(a, cardPath('a', 6)), cards('a', 6, [1])));
    await assertFails(setDoc(doc(a, cardPath('a', 6)), cards('a', 6, [1, 52])));
    await assertFails(setDoc(doc(a, cardPath('a', 6)), cards('a', 6, [1, 'As'])));
  });
  await test('doc id must be deviceId_entry', () =>
    assertFails(setDoc(doc(a, `${N}/cards/${DEV.a}_8`), cards('a', 7, [1, 2]))));
  await test("cannot write another phone's cards", async () => {
    await assertFails(setDoc(doc(b, cardPath('a', 7)), cards('b', 7, [1, 2], { deviceId: DEV.a })));
    await assertFails(setDoc(doc(b, cardPath('a', 3)), cards('b', 3, [1, 2], { deviceId: DEV.a })));
  });
  await test('non-member cannot write cards', () =>
    assertFails(setDoc(doc(x, cardPath('x', 1)), cards('x', 1, [1, 2]))));
  await test('unknown fields rejected', () =>
    assertFails(setDoc(doc(a, cardPath('a', 8)), cards('a', 8, [1, 2], { board: [3, 4, 5] }))));
  await test('the owner may correct its cards (the hold starts again)', () =>
    assertSucceeds(setDoc(doc(a, cardPath('a', 3)), cards('a', 3, [49, 48]))));
  await test("nobody deletes another phone's cards", () => assertFails(deleteDoc(doc(o, cardPath('a', 3)))));
  await test('the owner deletes its cards (sharing off)', () => assertSucceeds(deleteDoc(doc(a, cardPath('a', 3)))));

  console.log('tv');
  await test('the TV joins like a phone (it holds the code) and reads the logs', async () => {
    const tv = db('tv');
    await assertSucceeds(setDoc(doc(tv, `${N}/members/tv`), member('tv', { name: 'TV', deviceId: 'TVTVTVTV2345' })));
    await assertSucceeds(getDocs(collection(tv, `${N}/logs`)));
    await assertFails(getDocs(collection(tv, `${N}/cards`)));
  });

  console.log(`\n${passed} passed`);
  await env.cleanup();
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});

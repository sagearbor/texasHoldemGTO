// Security-rules tests for ../../firestore.rules (multi-phone table night),
// against the LOCAL Firestore emulator. Run ./run.sh.
//
// Cast: h = host (and board caller at first), a / b / c = players who
// joined, x = signed in but never joined, anon = not signed in.

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs, query, where,
  serverTimestamp, setLogLevel,
} = require('firebase/firestore');

// Denied writes are the point of most tests; keep the SDK quiet about them.
setLogLevel('silent');

const PROJECT = 'demo-feltnotes';
const CODE = 'ABC234';
const T = `tables/${CODE}`;

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
  const h = db('h'), a = db('a'), b = db('b'), c = db('c'), x = db('x');
  const anon = env.unauthenticatedContext().firestore();

  const table = (over = {}) => ({
    hostUid: 'h', name: 'Friday', createdAt: serverTimestamp(), closed: false,
    currentHand: 1, boardCaller: 'h', delayMin: 15,
    rotation: [{ from: 1, seats: ['h'], button: 0 }], names: { h: 'Host' },
    ...over,
  });
  const player = (name) => ({ name, sharing: false, joinedAt: serverTimestamp() });
  const entry = (uid, n, over = {}) => ({
    uid, handNo: n, action: 'fold', facing: 'unopened', position: 'UTG',
    hasCards: true, ts: serverTimestamp(), ...over,
  });
  const cards = (uid, n, revealed, over = {}) => ({
    uid, handNo: n, cards: [48, 44], revealed, ...over,
  });
  const board = (n, by, over = {}) => ({
    handNo: n, cards: [44, 21, 2], by, ts: serverTimestamp(), ...over,
  });

  console.log('table');
  await test('host creates a table with a valid code', () =>
    assertSucceeds(setDoc(doc(h, T), table())));
  await test('code must be 6 chars from the unambiguous alphabet', () =>
    assertFails(setDoc(doc(h, 'tables/ABC10O'), table())));
  await test('cannot create a table naming someone else as host', () =>
    assertFails(setDoc(doc(a, 'tables/QQQ222'), table({ hostUid: 'h' }))));
  await test('a new table starts at hand 1', () =>
    assertFails(setDoc(doc(h, 'tables/QQQ333'), table({ currentHand: 7 }))));
  await test('unknown fields are rejected', () =>
    assertFails(setDoc(doc(h, 'tables/QQQ444'), table({ stacks: { h: 100 } }))));
  await test('anyone signed in can fetch a table by code', () =>
    assertSucceeds(getDoc(doc(x, T))));
  await test('not signed in cannot fetch a table', () =>
    assertFails(getDoc(doc(anon, T))));
  await test('nobody can list tables (codes are not enumerable)', () =>
    assertFails(getDocs(collection(x, 'tables'))));

  console.log('joining');
  await test('host joins own table', () => assertSucceeds(setDoc(doc(h, `${T}/players/h`), player('Host'))));
  await test('a joins with a display name', () => assertSucceeds(setDoc(doc(a, `${T}/players/a`), player('Alice'))));
  await test('b joins', () => assertSucceeds(setDoc(doc(b, `${T}/players/b`), player('Bob'))));
  await test('c joins', () => assertSucceeds(setDoc(doc(c, `${T}/players/c`), player('Cy'))));
  await test('cannot create a player doc for someone else', () =>
    assertFails(setDoc(doc(x, `${T}/players/zz`), player('Zed'))));
  await test('cannot join already sharing', () =>
    assertFails(setDoc(doc(x, `${T}/players/x`), { ...player('X'), sharing: true })));
  await test('empty display name rejected', () =>
    assertFails(setDoc(doc(x, `${T}/players/x`), player(''))));
  await test('members can read the player list', () =>
    assertSucceeds(getDocs(collection(a, `${T}/players`))));
  await test('outsiders cannot read the player list', () =>
    assertFails(getDocs(collection(x, `${T}/players`))));
  await test('a player cannot remove another player', () =>
    assertFails(deleteDoc(doc(a, `${T}/players/b`))));

  console.log('seats and hand counter');
  await test('host sets the seat rotation (appends a segment)', () =>
    assertSucceeds(updateDoc(doc(h, T), {
      rotation: [{ from: 1, seats: ['h'], button: 0 }, { from: 1, seats: ['h', 'a', 'b', 'c'], button: 0 }],
      names: { h: 'Host', a: 'Alice', b: 'Bob', c: 'Cy' },
    })));
  await test('host cannot drop rotation history', () =>
    assertFails(updateDoc(doc(h, T), { rotation: [] })));
  await test('a member cannot edit the rotation', () =>
    assertFails(updateDoc(doc(a, T), { rotation: [1, 2, 3] })));
  await test('a member advances hand 1 -> 2', () =>
    assertSucceeds(updateDoc(doc(a, T), { currentHand: 2 })));
  await test('a second phone advancing the same deal is rejected (dedupe)', () =>
    assertFails(updateDoc(doc(b, T), { currentHand: 2 })));
  await test('a member cannot skip ahead two hands', () =>
    assertFails(updateDoc(doc(b, T), { currentHand: 4 })));
  await test('an outsider cannot advance', () =>
    assertFails(updateDoc(doc(x, T), { currentHand: 3 })));
  await test('a member cannot make themselves board caller', () =>
    assertFails(updateDoc(doc(a, T), { boardCaller: 'a' })));
  await test('host cannot move the hand counter backwards', () =>
    assertFails(updateDoc(doc(h, T), { currentHand: 1 })));
  await test('host cannot hand the table to someone else', () =>
    assertFails(updateDoc(doc(h, T), { hostUid: 'a' })));

  console.log('entries (public actions)');
  await test('a logs own action for hand 1', () =>
    assertSucceeds(setDoc(doc(a, `${T}/entries/a_1`), entry('a', 1))));
  await test('a late entry for an old hand is fine; current hand too', () =>
    assertSucceeds(setDoc(doc(a, `${T}/entries/a_2`), entry('a', 2, { action: 'raise' }))));
  await test('cannot log a hand that has not been dealt yet', () =>
    assertFails(setDoc(doc(a, `${T}/entries/a_3`), entry('a', 3))));
  await test('cannot write an entry as someone else', () =>
    assertFails(setDoc(doc(a, `${T}/entries/b_1`), entry('b', 1))));
  await test('doc id must be uid_handNo', () =>
    assertFails(setDoc(doc(a, `${T}/entries/a_9`), entry('a', 1))));
  await test('action must be fold/call/raise', () =>
    assertFails(setDoc(doc(b, `${T}/entries/b_1`), entry('b', 1, { action: 'allin' }))));
  await test('timestamp must be the server time', () =>
    assertFails(setDoc(doc(b, `${T}/entries/b_1`), entry('b', 1, { ts: 12345 }))));
  await test('hole cards cannot ride along in an entry', () =>
    assertFails(setDoc(doc(b, `${T}/entries/b_1`), entry('b', 1, { cards: [1, 2] }))));
  await test('b overwrites nothing of a', () =>
    assertFails(updateDoc(doc(b, `${T}/entries/a_1`), { action: 'call' })));
  await test('members read all entries (TV dashboard aggregates)', () =>
    assertSucceeds(getDocs(collection(c, `${T}/entries`))));
  await test('outsiders cannot read entries', () =>
    assertFails(getDocs(collection(x, `${T}/entries`))));

  console.log('boards');
  await test('board caller (host) records the flop for hand 1', () =>
    assertSucceeds(setDoc(doc(h, `${T}/boards/1`), board(1, 'h'))));
  await test('board caller adds turn and river', () =>
    assertSucceeds(updateDoc(doc(h, `${T}/boards/1`), { cards: [44, 21, 2, 30, 7], ts: serverTimestamp() })));
  await test('a non-caller cannot write a board', () =>
    assertFails(setDoc(doc(a, `${T}/boards/2`), board(2, 'a'))));
  await test('host delegates board calling to a', () =>
    assertSucceeds(updateDoc(doc(h, T), { boardCaller: 'a' })));
  await test('now a records the board for hand 2', () =>
    assertSucceeds(setDoc(doc(a, `${T}/boards/2`), board(2, 'a'))));
  await test('a board has 3 to 5 cards', () =>
    assertFails(setDoc(doc(a, `${T}/boards/2`), board(2, 'a', { cards: [1, 2, 3, 4, 5, 6] }))));
  await test('board doc id must match its hand number', () =>
    assertFails(setDoc(doc(a, `${T}/boards/1`), board(2, 'a'))));
  await test('members read boards (late entry matches by board)', () =>
    assertSucceeds(getDocs(collection(b, `${T}/boards`))));

  console.log('hole cards: privacy and give-to-get');
  // currentHand is 2 here: hand 1 is over, hand 2 is being played.
  await test('a stores hole cards for hand 1, not revealed', () =>
    assertSucceeds(setDoc(doc(a, `${T}/cards/a_1`), cards('a', 1, false))));
  await test('a reads own cards', () => assertSucceeds(getDoc(doc(a, `${T}/cards/a_1`))));
  await test('a queries own cards', () =>
    assertSucceeds(getDocs(query(collection(a, `${T}/cards`), where('uid', '==', 'a')))));
  await test('b cannot read a\'s unrevealed cards', () =>
    assertFails(getDoc(doc(b, `${T}/cards/a_1`))));
  await test('host cannot read a\'s unrevealed cards either', () =>
    assertFails(getDoc(doc(h, `${T}/cards/a_1`))));
  await test('cannot store cards as someone else', () =>
    assertFails(setDoc(doc(b, `${T}/cards/a_2`), cards('a', 2, false))));
  await test('cards must be two cards 0..51', () =>
    assertFails(setDoc(doc(b, `${T}/cards/b_1`), cards('b', 1, false, { cards: [12, 99] }))));
  await test('b stores and reveals cards for hand 1 (not sharing: give without get)', () =>
    assertSucceeds(setDoc(doc(b, `${T}/cards/b_1`), cards('b', 1, true, { cards: [0, 5] }))));
  await test('a (not sharing) cannot read b\'s revealed cards', () =>
    assertFails(getDoc(doc(a, `${T}/cards/b_1`))));
  await test('a (not sharing) cannot query revealed cards', () =>
    assertFails(getDocs(query(collection(a, `${T}/cards`), where('revealed', '==', true), where('handNo', '<', 2)))));
  await test('a turns sharing on', () =>
    assertSucceeds(updateDoc(doc(a, `${T}/players/a`), { sharing: true })));
  await test('sharing cannot be turned off again', () =>
    assertFails(updateDoc(doc(a, `${T}/players/a`), { sharing: false })));
  await test('now a reads b\'s revealed hand-1 cards', () =>
    assertSucceeds(getDoc(doc(a, `${T}/cards/b_1`))));
  await test('a sharer\'s new cards must be revealed', () =>
    assertFails(setDoc(doc(a, `${T}/cards/a_2`), cards('a', 2, false))));
  await test('a sharer stores revealed cards for the current hand', () =>
    assertSucceeds(setDoc(doc(a, `${T}/cards/a_2`), cards('a', 2, true))));
  await test('a sharer flips an old hidden hand to revealed', () =>
    assertSucceeds(updateDoc(doc(a, `${T}/cards/a_1`), { revealed: true })));
  await test('revealed cards cannot be un-revealed', () =>
    assertFails(updateDoc(doc(b, `${T}/cards/b_1`), { revealed: false })));
  await test('revealed cards cannot be deleted', () =>
    assertFails(deleteDoc(doc(b, `${T}/cards/b_1`))));
  await test('b (not sharing) still cannot read a\'s revealed cards', () =>
    assertFails(getDoc(doc(b, `${T}/cards/a_1`))));
  await test('b turns sharing on', () =>
    assertSucceeds(updateDoc(doc(b, `${T}/players/b`), { sharing: true })));
  await test('b reads a\'s revealed hand 1 (hand is over)', () =>
    assertSucceeds(getDoc(doc(b, `${T}/cards/a_1`))));
  await test('b cannot read a\'s revealed cards for the hand still in play', () =>
    assertFails(getDoc(doc(b, `${T}/cards/a_2`))));
  await test('b queries revealed cards of finished hands', async () => {
    const snap = await assertSucceeds(getDocs(query(
      collection(b, `${T}/cards`), where('revealed', '==', true), where('handNo', '<', 2))));
    const ids = snap.docs.map((d) => d.id).sort();
    if (ids.join() !== 'a_1,b_1') throw new Error(`got ${ids}`);
  });
  await test('a query that could include the hand in play is rejected', () =>
    assertFails(getDocs(query(collection(b, `${T}/cards`), where('revealed', '==', true), where('handNo', '<', 3)))));
  await test('a query without revealed == true is rejected', () =>
    assertFails(getDocs(query(collection(b, `${T}/cards`), where('handNo', '<', 2)))));
  await test('c (not sharing) cannot read anyone\'s cards', () =>
    assertFails(getDocs(query(collection(c, `${T}/cards`), where('revealed', '==', true), where('handNo', '<', 2)))));
  await test('outsiders cannot read cards even if they guess an id', () =>
    assertFails(getDoc(doc(x, `${T}/cards/a_1`))));
  await test('after the next deal, hand 2 opens to sharers', async () => {
    await assertSucceeds(updateDoc(doc(c, T), { currentHand: 3 }));
    await assertSucceeds(getDoc(doc(b, `${T}/cards/a_2`)));
  });

  console.log('closing');
  await test('host closes the night', () => assertSucceeds(updateDoc(doc(h, T), { closed: true })));
  await test('no more entries after close', () =>
    assertFails(setDoc(doc(c, `${T}/entries/c_1`), entry('c', 1))));
  await test('nobody can reopen or advance a closed night', () =>
    assertFails(updateDoc(doc(a, T), { currentHand: 4 })));
  await test('history stays readable to members', () =>
    assertSucceeds(getDocs(collection(c, `${T}/entries`))));

  await env.cleanup();
  console.log(`\n${passed} rules tests passed`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});

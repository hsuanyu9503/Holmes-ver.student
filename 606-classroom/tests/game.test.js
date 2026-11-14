'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const G = require('../server/game');

const GROUPS = [1, 2, 3, 4, 5, 6];

/** 23 人報到：第 1～5 組各 4 人、第 6 組 3 人 */
function classroom23(now = 1000) {
  const room = G.createRoom(now, 'TEST01');
  const students = [];
  let n = 0;
  for (const g of GROUPS) {
    const size = g === 6 ? 3 : 4;
    for (let i = 0; i < size; i++) students.push(G.join(room, { name: `學生${++n}`, group: g }, now));
  }
  return { room, students };
}
const T = (room, action, payload, now = 2000) => G.teacherAction(room, room.teacherKey, action, payload, now);
function selectFirstOfEachGroup(room, students, pick = () => 0) {
  for (const g of GROUPS) {
    const inGroup = students.filter((s) => s.group === g);
    T(room, 'select', { group: g, studentId: inGroup[pick(g) % inGroup.length].id });
  }
}
const playersOf = (room) => GROUPS.map((g) => room.students[room.round.players[g]]);
const roleOf = (room, s) => room.round.roles[s.id];

test('dice: blue 1–6 uniform, red 1/1/2/2/3/3 (1–3 uniform)', () => {
  const blue = Array(7).fill(0);
  const red = Array(4).fill(0);
  const N = 60000;
  for (let i = 0; i < N; i++) {
    const d = G.rollDice();
    blue[d.blue]++;
    red[d.red]++;
  }
  assert.equal(blue[0], 0);
  assert.equal(red[0], 0);
  for (let v = 1; v <= 6; v++) assert.ok(Math.abs(blue[v] / N - 1 / 6) < 0.012, `blue ${v}`);
  for (let v = 1; v <= 3; v++) assert.ok(Math.abs(red[v] / N - 1 / 3) < 0.012, `red ${v}`);
});

test('code map: 18 positions, each of the nine codes A1–C3 exactly twice', () => {
  for (let k = 0; k < 50; k++) {
    const map = G.makeCodeMap();
    assert.equal(map.length, 18);
    const counts = {};
    for (const c of map) counts[c] = (counts[c] || 0) + 1;
    assert.deepEqual(Object.keys(counts).sort(), [...G.CELL_CODES].sort());
    assert.ok(Object.values(counts).every((n) => n === 2));
    // 藍選列、紅選欄
    assert.equal(G.lookup(map, 1, 1), map[0]);
    assert.equal(G.lookup(map, 6, 3), map[17]);
    assert.equal(G.lookup(map, 4, 2), map[10]);
  }
});

test('check-in: refresh does not double count; teacher/display not counted; duplicate name guarded', () => {
  const { room, students } = classroom23();
  assert.equal(G.viewDisplay(room).count, 23);
  // 重整：帶原 token 重新報到 → 同一人
  const again = G.join(room, { token: students[0].token });
  assert.equal(again.id, students[0].id);
  assert.equal(G.viewDisplay(room).count, 23);
  // 同組同名（換裝置）→ 拒絕，老師允許後才可接回原紀錄
  assert.throws(() => G.join(room, { name: '學生1', group: 1 }), /已在第 1 組報到/);
  const oldToken = students[0].token;
  T(room, 'unlock', { studentId: students[0].id });
  const back = G.join(room, { name: '學生1', group: 1 });
  assert.equal(back.id, students[0].id);
  assert.notEqual(back.token, oldToken, 'reclaim issues a new token');
  assert.equal(G.studentByToken(room, oldToken), null, 'old device is signed out');
  assert.equal(G.viewDisplay(room).count, 23);
  // 驗證欄位
  assert.throws(() => G.join(room, { name: '', group: 1 }), /請輸入姓名/);
  assert.throws(() => G.join(room, { name: '小明', group: 7 }), /第 1～6 組/);
  // 教師金鑰錯誤
  assert.throws(() => G.teacherAction(room, 'bad', 'start'), /教師金鑰錯誤/);
});

test('start needs one player in each of the six groups; selection can be changed', () => {
  const { room, students } = classroom23();
  assert.throws(() => T(room, 'start'), /尚未選定玩家/);
  const g1 = students.filter((s) => s.group === 1);
  T(room, 'select', { group: 1, studentId: g1[0].id });
  T(room, 'select', { group: 1, studentId: g1[1].id }); // 改選
  assert.equal(room.selection[1], g1[1].id);
  assert.throws(() => T(room, 'select', { group: 2, studentId: g1[0].id }), /不在第 2 組/);
  selectFirstOfEachGroup(room, students, () => 1);
  T(room, 'start');
  assert.equal(room.phase, 'identity');
});

test('roles: exactly 5 agents + 1 spy among the six players, 17 insiders', () => {
  for (let k = 0; k < 30; k++) {
    const { room, students } = classroom23();
    selectFirstOfEachGroup(room, students);
    T(room, 'start');
    const roles = Object.values(room.round.roles);
    assert.equal(roles.filter((r) => r === 'agent').length, 5);
    assert.equal(roles.filter((r) => r === 'spy').length, 1);
    assert.equal(roles.filter((r) => r === 'insider').length, 17);
    for (const p of playersOf(room)) assert.notEqual(roleOf(room, p), 'insider');
  }
});

test('flip gating: 5 players + all 17 insiders flipped still blocks; 6 players flipped allows even with insiders pending', () => {
  const { room, students } = classroom23();
  selectFirstOfEachGroup(room, students);
  T(room, 'start');
  const players = playersOf(room);
  const insiders = students.filter((s) => roleOf(room, s) === 'insider');
  for (const p of players.slice(0, 5)) G.flip(room, p.token);
  for (const s of insiders) G.flip(room, s.token);
  let prog = G.flipProgress(room);
  assert.deepEqual(prog, { playersFlipped: 5, playersTotal: 6, insidersFlipped: 17, insidersTotal: 17 });
  assert.throws(() => T(room, 'roll'), /還有 1 名玩家尚未翻牌/);

  // 另一局：六名玩家都翻牌、局內人都沒翻 → 可擲骰
  const b = classroom23();
  selectFirstOfEachGroup(b.room, b.students);
  T(b.room, 'start');
  for (const p of playersOf(b.room)) G.flip(b.room, p.token);
  prog = G.flipProgress(b.room);
  assert.equal(prog.playersFlipped, 6);
  assert.equal(prog.insidersFlipped, 0);
  T(b.room, 'roll');
  assert.equal(b.room.phase, 'dice');
});

/** 遞迴搜尋 view 中是否出現某個值或欄位 */
function deepHas(obj, pred) {
  if (obj == null) return false;
  if (typeof obj !== 'object') return pred(obj, null);
  return Object.entries(obj).some(([k, v]) => pred(v, k) || deepHas(v, pred));
}

test('privacy: before the ending, spy and display never receive code map, secret code or answer mark', () => {
  const { room, students } = classroom23();
  selectFirstOfEachGroup(room, students);
  T(room, 'start', {}, 2000);
  const players = playersOf(room);
  const spy = players.find((p) => roleOf(room, p) === 'spy');
  const agent = players.find((p) => roleOf(room, p) === 'agent');
  const insider = students.find((s) => roleOf(room, s) === 'insider');

  // 未翻牌：連本人身分都不給
  assert.equal(G.viewStudent(room, agent, 2100).card.role, null);
  for (const p of players) G.flip(room, p.token, 2200);
  G.flip(room, insider.token, 2200);
  T(room, 'roll', {}, 3000);
  const secret = room.round.secretCode;
  const forbiddenKeys = new Set(['codeMap', 'secretCode', 'spyId', 'roles', 'code_map']);
  const leaks = (v) => deepHas(v, (val, k) => forbiddenKeys.has(k) || val === secret || (Array.isArray(val) && val.length === 18));

  // 動畫期間（未揭曉）：任何人都拿不到代碼
  for (const s of [agent, insider, spy]) assert.equal(G.viewStudent(room, s, 3000 + 1000).card.intel, null);
  assert.equal(G.viewDisplay(room, 4000).dice.revealed, false);

  // 揭曉後
  const t = 3000 + G.REVEAL_DELAY_MS;
  const va = G.viewStudent(room, agent, t);
  const vi = G.viewStudent(room, insider, t);
  const vs = G.viewStudent(room, spy, t);
  assert.equal(va.card.intel.code, secret);
  assert.equal(vi.card.intel.code, secret, 'insider gets the same code as agents');
  assert.equal(vs.card.intel.code, undefined);
  assert.equal(vs.card.intel.mission, G.SPY_MISSION);
  assert.ok(!leaks(vs), 'spy view leaks');
  const vd = G.viewDisplay(room, t);
  assert.deepEqual([vd.dice.blue, vd.dice.red], [room.round.dice.blue, room.round.dice.red]);
  assert.ok(!leaks(vd), 'display view leaks');
  assert.ok(!leaks(G.viewTeacher(room, t)), 'teacher view leaks before ending');

  // 公開情報卡：九個詞語相同、無答案標記
  T(room, 'publish', {}, t);
  const boards = [G.viewDisplay(room, t), G.viewStudent(room, spy, t), G.viewStudent(room, agent, t), G.viewTeacher(room, t)].map((v) => v.board);
  for (const b of boards) assert.deepEqual(b, boards[0]);
  assert.deepEqual(Object.keys(boards[0]).sort(), ['cols', 'rows', 'title', 'words']);
  assert.ok(!leaks(G.viewStudent(room, spy, t)));
  assert.ok(!leaks(G.viewDisplay(room, t)));
});

test('publish waits for dice animation to finish', () => {
  const { room, students } = classroom23();
  selectFirstOfEachGroup(room, students);
  T(room, 'start');
  for (const p of playersOf(room)) G.flip(room, p.token);
  T(room, 'roll', {}, 5000);
  assert.throws(() => T(room, 'publish', {}, 5000 + 1000), /動畫尚未結束/);
  T(room, 'publish', {}, 5000 + G.REVEAL_DELAY_MS);
  assert.equal(room.phase, 'card');
});

function playToCard() {
  const { room, students } = classroom23();
  selectFirstOfEachGroup(room, students);
  T(room, 'start');
  for (const p of playersOf(room)) G.flip(room, p.token);
  T(room, 'roll', {}, 5000);
  T(room, 'publish', {}, 9000);
  const spyGroup = GROUPS.find((g) => room.round.players[g] === room.round.spyId);
  return { room, students, spyGroup };
}

test('ending 1: wrong accusation → 臥底勝利！ (指認錯人)', () => {
  const { room, spyGroup } = playToCard();
  assert.ok(!G.viewDisplay(room, 9000).ending);
  T(room, 'accuse', { group: (spyGroup % 6) + 1 });
  const e = G.viewDisplay(room).ending;
  assert.equal(room.phase, 'ending');
  assert.equal(e.title, '臥底勝利！');
  assert.equal(e.reason, '玩家指認錯人，臥底成功隱藏身分。');
  assert.equal(e.img, 'end-spy');
  assert.equal(e.spyGroup, spyGroup);
  assert.equal(e.secretCode, room.round.secretCode);
});

test('ending 2: tie after revote → 臥底勝利！ (再次投票仍平手)', () => {
  const { room } = playToCard();
  T(room, 'step', { step: 'revote' });
  T(room, 'tie');
  const e = G.viewDisplay(room).ending;
  assert.equal(e.title, '臥底勝利！');
  assert.equal(e.reason, '再次投票仍平手，臥底成功逃過指認。');
  assert.equal(e.img, 'end-spy');
});

test('ending 3: spy caught, correct last guess → 臥底逆轉勝利！', () => {
  const { room, spyGroup } = playToCard();
  T(room, 'accuse', { group: spyGroup });
  assert.equal(room.phase, 'guess');
  // 猜詞階段仍不洩漏答案
  assert.equal(G.viewDisplay(room).ending, null);
  assert.equal(G.viewDisplay(room).accusedGroup, spyGroup);
  T(room, 'guess', { code: room.round.secretCode });
  const e = G.viewDisplay(room).ending;
  assert.equal(e.title, '臥底逆轉勝利！');
  assert.equal(e.reason, '臥底猜中機密詞語，成功逆轉。');
  assert.equal(e.img, 'end-spy-reverse');
});

test('ending 4: spy caught, wrong last guess → 情報員勝利！', () => {
  const { room, spyGroup } = playToCard();
  T(room, 'accuse', { group: spyGroup });
  const wrong = G.CELL_CODES.find((c) => c !== room.round.secretCode);
  T(room, 'guess', { code: wrong });
  const e = G.viewDisplay(room).ending;
  assert.equal(e.title, '情報員勝利！');
  assert.equal(e.reason, '情報員成功揪出臥底，守住機密詞語。');
  assert.equal(e.img, 'end-agents');
  assert.equal(e.guessCode, wrong);
});

test('next round: roster kept, previous six preselected, swaps produce correct new roles and fresh flip counts', () => {
  const { room, students, spyGroup } = playToCard();
  const prevPlayers = playersOf(room);
  T(room, 'tie');
  T(room, 'next');
  assert.equal(room.phase, 'lobby');
  assert.equal(room.roundNo, 2);
  assert.equal(room.round, null);
  assert.equal(G.viewDisplay(room).count, 23);
  for (const g of GROUPS) assert.equal(room.selection[g], prevPlayers[g - 1].id);

  // 換掉第 1、2、3 組：上一輪玩家轉局內人、局內人轉玩家
  const swappedOut = prevPlayers.slice(0, 3);
  const swappedIn = [1, 2, 3].map((g) => students.find((s) => s.group === g && !prevPlayers.some((p) => p.id === s.id)));
  [1, 2, 3].forEach((g, i) => T(room, 'select', { group: g, studentId: swappedIn[i].id }));
  T(room, 'start');
  const r = room.round;
  assert.equal(r.no, 2);
  for (const s of swappedOut) assert.equal(roleOf(room, s), 'insider');
  for (const s of swappedIn) assert.notEqual(roleOf(room, s), 'insider');
  const roles = Object.values(r.roles);
  assert.equal(roles.filter((x) => x === 'spy').length, 1);
  assert.equal(roles.filter((x) => x === 'agent').length, 5);
  assert.equal(roles.filter((x) => x === 'insider').length, 17);
  // 全部回到卡背、計數歸零、骰點與代碼清空
  assert.deepEqual(G.flipProgress(room), { playersFlipped: 0, playersTotal: 6, insidersFlipped: 0, insidersTotal: 17 });
  for (const s of students) {
    const v = G.viewStudent(room, s);
    assert.equal(v.card.flipped, false);
    assert.equal(v.card.role, null);
    assert.equal(v.card.intel, null);
    assert.equal(v.board, null);
    assert.equal(v.ending, null);
  }
  assert.equal(r.dice, null);
  assert.equal(r.secretCode, null);
  // 舊玩家（現為局內人）翻牌只影響局內人計數
  G.flip(room, swappedOut[0].token);
  assert.deepEqual(G.flipProgress(room), { playersFlipped: 0, playersTotal: 6, insidersFlipped: 1, insidersTotal: 17 });
  G.flip(room, swappedIn[0].token);
  assert.equal(G.flipProgress(room).playersFlipped, 1);
  assert.equal(G.viewStudent(room, swappedIn[0]).card.isPlayer, true);
  assert.equal(G.viewStudent(room, swappedOut[0]).card.role, 'insider');
  assert.ok(spyGroup);
});

test('reconnect in the same round keeps role and flip; late joiner becomes insider', () => {
  const { room, students } = classroom23();
  selectFirstOfEachGroup(room, students);
  T(room, 'start');
  const p = playersOf(room)[2];
  G.flip(room, p.token, 3000);
  const back = G.join(room, { token: p.token });
  const v = G.viewStudent(room, back);
  assert.equal(v.card.flipped, true);
  assert.equal(v.card.role, room.round.roles[p.id]);
  const late = G.join(room, { name: '遲到生', group: 4 });
  assert.equal(room.round.roles[late.id], 'insider');
  assert.equal(G.flipProgress(room).insidersTotal, 18);
});

test('abort returns to lobby without advancing; players cannot be removed mid-round', () => {
  const { room, students } = classroom23();
  selectFirstOfEachGroup(room, students);
  T(room, 'start');
  const p = playersOf(room)[0];
  assert.throws(() => T(room, 'remove', { studentId: p.id }), /本輪玩家無法移除/);
  T(room, 'abort');
  assert.equal(room.phase, 'lobby');
  assert.equal(room.roundNo, 1);
  assert.equal(room.selection[1], p.id);
  T(room, 'remove', { studentId: p.id });
  assert.equal(room.selection[1], null);
  assert.equal(G.viewDisplay(room).count, 22);
});

test('custom deck validation and use', () => {
  const { room, students } = classroom23();
  assert.throws(() => T(room, 'deck', { choice: 'custom', custom: { title: '測試', words: ['a'] } }), /九個詞語/);
  assert.throws(() => T(room, 'deck', { choice: 'custom', custom: { title: '測試', words: Array(9).fill('同') } }), /不可重複/);
  const words = ['一', '二', '三', '四', '五', '六', '七', '八', '九'];
  T(room, 'deck', { choice: 'custom', custom: { title: '數字', words } });
  selectFirstOfEachGroup(room, students);
  T(room, 'start');
  assert.deepEqual(room.round.deck.words, words);
});

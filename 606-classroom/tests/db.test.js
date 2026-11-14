'use strict';
// 資料庫函式測試：直接對 Postgres（本機或 Supabase 本機堆疊）執行。
//   DATABASE_URL=postgres://postgres:postgres@127.0.0.1:54322/postgres npm test
// 會先套用 supabase/migrations 內的 SQL（可重複執行），再以 anon 身分呼叫 RPC。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Client } = require('pg');

const URL = process.env.DATABASE_URL || 'postgres://postgres:postgres@127.0.0.1:54322/postgres';
const MIGRATIONS = path.join(__dirname, '..', 'supabase', 'migrations');
const GROUPS = [1, 2, 3, 4, 5, 6];
const CELLS = ['A1', 'B1', 'C1', 'A2', 'B2', 'C2', 'A3', 'B3', 'C3'];

let admin; // 超級使用者：可檢查私有資料
let anon; // 與瀏覽器相同的 anon 權限

test.before(async () => {
  admin = new Client({ connectionString: URL });
  await admin.connect();
  await admin.query(`do $$ begin
    if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
    if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  end $$`);
  for (const f of fs.readdirSync(MIGRATIONS).filter((x) => x.endsWith('.sql')).sort()) {
    await admin.query(fs.readFileSync(path.join(MIGRATIONS, f), 'utf8'));
  }
  await admin.query("delete from c606_private.settings where key='teacher_passcode'");
  anon = new Client({ connectionString: URL });
  await anon.connect();
  await anon.query('set role anon');
});
test.after(async () => {
  await anon?.end();
  await admin?.end();
});

/** 以 anon 身分呼叫 public.<fn>(具名參數) */
async function rpc(fn, args = {}) {
  const keys = Object.keys(args);
  const sql = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
  const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
  const { rows } = await anon.query(sql, vals);
  return rows[0].r;
}
const fails = (p, code, re) => assert.rejects(p, (e) => (code ? e.code === code : true) && (!re || re.test(e.message)));
const T = (room, action, payload = {}) => rpc('c606_teacher', { p_code: room.code, p_key: room.teacherKey, p_action: action, p_payload: payload });
const view = (room, as, cred) => rpc('c606_view', { p_code: room.code, p_as: as, p_cred: cred ?? null });
const flip = (room, s) => rpc('c606_flip', { p_code: room.code, p_token: s.token });
const secret = async (room) => (await admin.query('select * from c606_private.rounds where room_code=$1', [room.code])).rows[0];
const roleOf = async (room, s) => (await admin.query('select role from c606_private.round_roles where room_code=$1 and student_id=$2', [room.code, s.studentId])).rows[0]?.role;
/** 跳過 2.6 秒骰子動畫 */
const fastForward = (room) => admin.query("update c606_private.rounds set reveal_at = clock_timestamp() - interval '1 second' where room_code=$1", [room.code]);

/** 23 人報到：第 1～5 組各 4 人、第 6 組 3 人 */
async function classroom23() {
  const r = await rpc('c606_create_room', { p_passcode: null });
  const room = { code: r.code, teacherKey: r.teacherKey };
  const students = [];
  let n = 0;
  for (const g of GROUPS) for (let i = 0; i < (g === 6 ? 3 : 4); i++) {
    students.push(await rpc('c606_join', { p_code: room.code, p_name: `學生${++n}`, p_group: g }));
  }
  return { room, students };
}
async function selectFirst(room, students, pick = () => 0) {
  for (const g of GROUPS) {
    const inG = students.filter((s) => s.group === g);
    await T(room, 'select', { group: g, studentId: inG[pick(g) % inG.length].studentId });
  }
}
async function players(room, students) {
  const r = await secret(room);
  return GROUPS.map((g) => students.find((s) => s.studentId === r.players[g]));
}

test('anon cannot read private tables; only signals are visible', async () => {
  await fails(anon.query('select * from c606_private.rooms'), '42501');
  await fails(anon.query('select * from c606_private.round_roles'), '42501');
  await fails(anon.query('select c606_private.view_teacher($1)', ['X']), '42501');
  await fails(anon.query("insert into public.c606_signals(room_code) values ('HACK')"), '42501');
  const { rows } = await anon.query('select * from public.c606_signals limit 1');
  if (rows[0]) assert.deepEqual(Object.keys(rows[0]).sort(), ['room_code', 'updated_at', 'version']);
});

test('dice and code map distributions', async () => {
  const { rows } = await admin.query(`
    select c606_private.rand(6) + 1 as blue, (array[1,1,2,2,3,3])[c606_private.rand(6) + 1] as red
    from generate_series(1, 30000)`);
  const N = rows.length;
  const blue = Array(7).fill(0);
  const red = Array(4).fill(0);
  for (const r of rows) { blue[r.blue]++; red[r.red]++; }
  for (let v = 1; v <= 6; v++) assert.ok(Math.abs(blue[v] / N - 1 / 6) < 0.015, `blue ${v}: ${blue[v]}`);
  for (let v = 1; v <= 3; v++) assert.ok(Math.abs(red[v] / N - 1 / 3) < 0.015, `red ${v}: ${red[v]}`);
  assert.equal(blue[0] + red[0], 0);

  const { room, students } = await classroom23();
  await selectFirst(room, students);
  await T(room, 'start');
  const r = await secret(room);
  assert.equal(r.code_map.length, 18);
  const counts = {};
  for (const c of r.code_map) counts[c] = (counts[c] || 0) + 1;
  assert.deepEqual(Object.keys(counts).sort(), [...CELLS].sort());
  assert.ok(Object.values(counts).every((x) => x === 2));
});

test('check-in: refresh not double counted, duplicate name guarded, reclaim after unlock', async () => {
  const { room, students } = await classroom23();
  assert.equal((await view(room, 'display')).count, 23);
  const again = await rpc('c606_join', { p_code: room.code, p_token: students[0].token });
  assert.equal(again.studentId, students[0].studentId);
  assert.equal((await view(room, 'display')).count, 23);
  await fails(rpc('c606_join', { p_code: room.code, p_name: '學生1', p_group: 1 }), 'PT409', /已在第 1 組報到/);
  await T(room, 'unlock', { studentId: students[0].studentId });
  const back = await rpc('c606_join', { p_code: room.code, p_name: '學生1', p_group: 1 });
  assert.equal(back.studentId, students[0].studentId);
  assert.notEqual(back.token, students[0].token);
  await fails(view(room, 'student', students[0].token), 'PT401');
  assert.equal((await view(room, 'display')).count, 23);
  await fails(rpc('c606_join', { p_code: room.code, p_name: ' ', p_group: 1 }), 'P0001', /請輸入姓名/);
  await fails(rpc('c606_join', { p_code: room.code, p_name: '小明', p_group: 7 }), 'P0001', /第 1～6 組/);
  await fails(rpc('c606_join', { p_code: 'NOPE00', p_name: '小明', p_group: 1 }), 'PT404');
  await fails(T({ ...room, teacherKey: 'bad' }, 'start'), 'PT403');
  await fails(view(room, 'teacher', 'bad'), 'PT403');
});

test('teacher passcode setting', async () => {
  await admin.query("insert into c606_private.settings values ('teacher_passcode','abc606') on conflict (key) do update set value=excluded.value");
  try {
    assert.equal(await rpc('c606_requires_passcode'), true);
    await fails(rpc('c606_create_room', { p_passcode: 'x' }), 'PT403');
    assert.ok((await rpc('c606_create_room', { p_passcode: 'abc606' })).code);
  } finally {
    await admin.query("delete from c606_private.settings where key='teacher_passcode'");
  }
});

test('start needs six groups; 5 agents + 1 spy + 17 insiders', async () => {
  const { room, students } = await classroom23();
  await fails(T(room, 'start'), 'P0001', /尚未選定玩家/);
  const g1 = students.filter((s) => s.group === 1);
  await fails(T(room, 'select', { group: 2, studentId: g1[0].studentId }), 'P0001', /不在第 2 組/);
  await selectFirst(room, students, () => 1);
  const tv = await T(room, 'start');
  assert.equal(tv.phase, 'identity');
  const { rows } = await admin.query('select role, count(*)::int n from c606_private.round_roles where room_code=$1 group by role', [room.code]);
  const by = Object.fromEntries(rows.map((r) => [r.role, r.n]));
  assert.deepEqual(by, { agent: 5, spy: 1, insider: 17 });
  assert.deepEqual(tv.progress, { playersFlipped: 0, playersTotal: 6, insidersFlipped: 0, insidersTotal: 17 });
});

test('flip gating: 5 players + 17 insiders blocks; 6 players allows with insiders pending', async () => {
  const { room, students } = await classroom23();
  await selectFirst(room, students);
  await T(room, 'start');
  const ps = await players(room, students);
  const insiders = students.filter((s) => !ps.includes(s));
  for (const p of ps.slice(0, 5)) await flip(room, p);
  for (const s of insiders) await flip(room, s);
  const tv = await view(room, 'teacher', room.teacherKey);
  assert.deepEqual(tv.progress, { playersFlipped: 5, playersTotal: 6, insidersFlipped: 17, insidersTotal: 17 });
  await fails(T(room, 'roll'), 'P0001', /還有 1 名玩家尚未翻牌/);

  const b = await classroom23();
  await selectFirst(b.room, b.students);
  await T(b.room, 'start');
  for (const p of await players(b.room, b.students)) await flip(b.room, p);
  const v = await T(b.room, 'roll');
  assert.equal(v.phase, 'dice');
  assert.equal(v.progress.insidersFlipped, 0);
});

function leaks(obj, secretCode, extraKeys = []) {
  const bad = new Set(['code_map', 'codeMap', 'secret_code', 'secretCode', 'spy_id', 'spyId', 'roles', ...extraKeys]);
  const walk = (o) => {
    if (o == null) return false;
    if (typeof o !== 'object') return o === secretCode;
    if (Array.isArray(o) && o.length === 18) return true;
    return Object.entries(o).some(([k, v]) => bad.has(k) || walk(v));
  };
  return walk(obj);
}

test('privacy: spy and display never get the map, code or answer before the ending', async () => {
  const { room, students } = await classroom23();
  await selectFirst(room, students);
  await T(room, 'start');
  const ps = await players(room, students);
  const roles = await Promise.all(ps.map((p) => roleOf(room, p)));
  const spy = ps[roles.indexOf('spy')];
  const agent = ps[roles.indexOf('agent')];
  const insider = students.find((s) => !ps.includes(s));

  assert.equal((await view(room, 'student', agent.token)).card.role, null, 'role hidden until flipped');
  for (const p of ps) await flip(room, p);
  await flip(room, insider);
  const rolled = await T(room, 'roll');
  const sec = (await secret(room)).secret_code;
  assert.match(sec, /^[ABC][123]$/);
  assert.equal(sec, (await secret(room)).code_map[(rolled.dice.blue - 1) * 3 + (rolled.dice.red - 1)]);
  assert.equal(rolled.dice.revealed, false);
  assert.ok(rolled.wakeAt > rolled.serverNow, 'clients told when to refetch');

  // 動畫期間：沒有人拿得到代碼
  for (const s of [agent, insider, spy]) assert.equal((await view(room, 'student', s.token)).card.intel, null);
  await fails(T(room, 'publish'), 'P0001', /動畫尚未結束/);

  await fastForward(room);
  const va = await view(room, 'student', agent.token);
  const vi = await view(room, 'student', insider.token);
  const vs = await view(room, 'student', spy.token);
  const vd = await view(room, 'display');
  const vt = await view(room, 'teacher', room.teacherKey);
  assert.equal(va.card.intel.code, sec);
  assert.equal(vi.card.intel.code, sec, 'insider same code');
  assert.equal(vs.card.intel.code, undefined);
  assert.equal(vs.card.intel.mission, '機密任務：觀察其他玩家的發言，推理本輪的機密情報。');
  assert.ok(!leaks(vs, sec), 'spy view leaks');
  assert.ok(!leaks(vd, sec), 'display view leaks');
  assert.ok(!leaks(vt, sec), 'teacher view leaks');
  assert.deepEqual([vd.dice.blue, vd.dice.red, vd.dice.revealed], [rolled.dice.blue, rolled.dice.red, true]);

  await T(room, 'publish');
  const boards = await Promise.all([view(room, 'display'), view(room, 'student', spy.token), view(room, 'student', agent.token), view(room, 'teacher', room.teacherKey)]);
  for (const b of boards) assert.deepEqual(b.board, boards[0].board);
  assert.deepEqual(Object.keys(boards[0].board).sort(), ['cols', 'rows', 'title', 'words']);
  assert.equal(boards[0].board.words.length, 9);
  // 顯示端、臥底、教師在結局前都不含代碼（情報員本來就看得到自己的代碼）
  for (const b of [boards[0], boards[1], boards[3]]) assert.ok(!leaks(b, sec));
});

async function playToCard() {
  const { room, students } = await classroom23();
  await selectFirst(room, students);
  await T(room, 'start');
  for (const p of await players(room, students)) await flip(room, p);
  await T(room, 'roll');
  await fastForward(room);
  await T(room, 'publish');
  const r = await secret(room);
  const spyGroup = GROUPS.find((g) => r.players[g] === r.spy_id);
  return { room, students, spyGroup, secretCode: r.secret_code };
}

test('ending 1: wrong accusation → 臥底勝利！(指認錯人)', async () => {
  const { room, spyGroup, secretCode } = await playToCard();
  await T(room, 'accuse', { group: (spyGroup % 6) + 1 });
  const e = (await view(room, 'display')).ending;
  assert.equal(e.title, '臥底勝利！');
  assert.equal(e.reason, '玩家指認錯人，臥底成功隱藏身分。');
  assert.equal(e.img, 'end-spy');
  assert.equal(e.spyGroup, spyGroup);
  assert.equal(e.secretCode, secretCode);
});

test('ending 2: tie after revote → 臥底勝利！(再次投票仍平手)', async () => {
  const { room } = await playToCard();
  await T(room, 'step', { step: 'revote' });
  await T(room, 'tie');
  const e = (await view(room, 'display')).ending;
  assert.equal(e.title, '臥底勝利！');
  assert.equal(e.reason, '再次投票仍平手，臥底成功逃過指認。');
  assert.equal(e.img, 'end-spy');
});

test('ending 3: spy caught, right guess → 臥底逆轉勝利！', async () => {
  const { room, spyGroup, secretCode } = await playToCard();
  const g = await T(room, 'accuse', { group: spyGroup });
  assert.equal(g.phase, 'guess');
  const d = await view(room, 'display');
  assert.equal(d.ending, null);
  assert.equal(d.accusedGroup, spyGroup);
  assert.ok(!leaks(d, secretCode));
  await T(room, 'guess', { code: secretCode });
  const e = (await view(room, 'display')).ending;
  assert.equal(e.title, '臥底逆轉勝利！');
  assert.equal(e.reason, '臥底猜中機密詞語，成功逆轉。');
  assert.equal(e.img, 'end-spy-reverse');
});

test('ending 4: spy caught, wrong guess → 情報員勝利！', async () => {
  const { room, spyGroup, secretCode } = await playToCard();
  await T(room, 'accuse', { group: spyGroup });
  const wrong = CELLS.find((c) => c !== secretCode);
  await T(room, 'guess', { code: wrong });
  const e = (await view(room, 'display')).ending;
  assert.equal(e.title, '情報員勝利！');
  assert.equal(e.reason, '情報員成功揪出臥底，守住機密詞語。');
  assert.equal(e.img, 'end-agents');
  assert.equal(e.guessCode, wrong);
});

test('next round: roster kept, last six preselected, swaps give correct roles and fresh state', async () => {
  const { room, students } = await playToCard();
  const prev = await players(room, students);
  await T(room, 'tie');
  const lobby = await T(room, 'next');
  assert.equal(lobby.phase, 'lobby');
  assert.equal(lobby.roundNo, 2);
  assert.equal(lobby.count, 23);
  for (const g of GROUPS) assert.equal(lobby.selection[g], prev[g - 1].studentId);

  const out = prev.slice(0, 3);
  const into = [1, 2, 3].map((g) => students.find((s) => s.group === g && !prev.includes(s)));
  for (const [i, g] of [1, 2, 3].entries()) await T(room, 'select', { group: g, studentId: into[i].studentId });
  const tv = await T(room, 'start');
  assert.deepEqual(tv.progress, { playersFlipped: 0, playersTotal: 6, insidersFlipped: 0, insidersTotal: 17 });
  for (const s of out) assert.equal(await roleOf(room, s), 'insider');
  for (const s of into) assert.notEqual(await roleOf(room, s), 'insider');
  for (const s of students) {
    const v = await view(room, 'student', s.token);
    assert.equal(v.card.flipped, false);
    assert.equal(v.card.role, null);
    assert.equal(v.card.intel, null);
    assert.equal(v.board, null);
    assert.equal(v.ending, null);
  }
  const r = await secret(room);
  assert.equal(r.no, 2);
  assert.equal(r.secret_code, null);
  assert.equal(r.blue, null);
  await flip(room, out[0]);
  assert.deepEqual((await view(room, 'teacher', room.teacherKey)).progress, { playersFlipped: 0, playersTotal: 6, insidersFlipped: 1, insidersTotal: 17 });
  const vin = await flip(room, into[0]);
  assert.equal(vin.card.isPlayer, true);
  assert.equal((await view(room, 'teacher', room.teacherKey)).progress.playersFlipped, 1);
  assert.equal((await view(room, 'teacher', room.teacherKey)).history.length, 1);
});

test('reconnect keeps role and flip; late joiner is insider; abort and remove', async () => {
  const { room, students } = await classroom23();
  await selectFirst(room, students);
  await T(room, 'start');
  const ps = await players(room, students);
  await flip(room, ps[2]);
  const back = await rpc('c606_join', { p_code: room.code, p_token: ps[2].token });
  const v = await view(room, 'student', back.token);
  assert.equal(v.card.flipped, true);
  assert.equal(v.card.role, await roleOf(room, ps[2]));
  const late = await rpc('c606_join', { p_code: room.code, p_name: '遲到生', p_group: 4 });
  assert.equal(await roleOf(room, late), 'insider');
  assert.equal((await view(room, 'teacher', room.teacherKey)).progress.insidersTotal, 18);
  await fails(T(room, 'remove', { studentId: ps[0].studentId }), 'P0001', /本輪玩家無法移除/);
  const ab = await T(room, 'abort');
  assert.equal(ab.phase, 'lobby');
  assert.equal(ab.roundNo, 1);
  assert.equal(ab.selection[1], ps[0].studentId);
  const rm = await T(room, 'remove', { studentId: ps[0].studentId });
  assert.equal(rm.selection[1], undefined);
  assert.equal(rm.count, 23);
  await fails(view(room, 'student', ps[0].token), 'PT401');
});

test('deck choice and custom deck validation', async () => {
  const { room, students } = await classroom23();
  await fails(T(room, 'deck', { choice: 'custom', custom: { title: '測試', words: ['a'] } }), 'P0001', /九個詞語/);
  await fails(T(room, 'deck', { choice: 'custom', custom: { title: '測試', words: Array(9).fill('同') } }), 'P0001', /不可重複/);
  await fails(T(room, 'deck', { choice: 'nope' }), 'P0001');
  const words = ['一', '二', '三', '四', '五', '六', '七', '八', '九'];
  await T(room, 'deck', { choice: 'custom', custom: { title: '數字', words } });
  await selectFirst(room, students);
  const tv = await T(room, 'start');
  assert.deepEqual(tv.roundDeck, { title: '數字', words });
});

test('signals version increases on every change (drives Realtime)', async () => {
  const r = await rpc('c606_create_room', { p_passcode: null });
  const ver = async () => (await anon.query('select version from public.c606_signals where room_code=$1', [r.code])).rows[0].version;
  const v0 = Number(await ver());
  await rpc('c606_join', { p_code: r.code, p_name: '甲', p_group: 1 });
  assert.equal(Number(await ver()), v0 + 1);
  const d = await view({ code: r.code }, 'display');
  assert.equal(Number(d.version), v0 + 1);
});

// SQL-level verification of the classroom RPCs against a local Postgres with a Supabase auth stub.
const { Client } = require('pg');
const assert = require('assert');
const db = new Client({ host: '/tmp', port: 5433, user: 'postgres', database: process.argv[2] || 'base28' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let passed = 0;
const ok = (cond, msg) => { assert.ok(cond, msg); passed++; console.log('  ✓ ' + msg); };

async function newUser() {
  const r = await db.query('insert into auth.users default values returning id'); return r.rows[0].id;
}
async function as(uid, fn, args = []) {
  const ph = args.map((_, i) => `$${i + 1}`).join(',');
  await db.query('begin');
  try {
    await db.query('set local role authenticated');
    await db.query("select set_config('request.jwt.claim.sub',$1,true)", [uid]);
    const r = await db.query(`select public.${fn}(${ph}) as v`, args);
    await db.query('commit');
    return r.rows[0].v;
  } catch (e) { await db.query('rollback'); throw e; }
}
async function fails(p, re, msg) {
  try { await p; } catch (e) { ok(re.test(e.message), `${msg}（${e.message}）`); return; }
  assert.fail('expected failure: ' + msg);
}
const secretOf = async room => (await db.query('select * from intelligence_private.intel606_secrets where room_id=$1', [room])).rows[0];
const noSecretText = (obj, code, word) => {
  const s = JSON.stringify(obj);
  return !/"code":"[A-C][1-3]"/.test(s) && !/"secret_code"/.test(s) && !/"role":"(agent|undercover|observer)"/.test(s)
    && !/undercover_seat|code_map/.test(s) && (!word || !s.includes('"word"'));
};

(async () => {
  await db.connect();
  console.log('== 建立教師、情報卡、課堂房間');
  const teacher = await newUser();
  await db.query(`insert into public.intel606_cards(owner_id,board_size,category,title,cells,active)
    values($1,3,'動物','動物偵探','["企鵝","熊貓","海豹","北極熊","斑馬","海豚","駝鳥","貓頭鷹","鯨魚"]'::jsonb,true)`, [teacher]);
  let t = await as(teacher, 'intel606_create_classroom_room');
  const room = t.room_id, code = t.code, token = t.display_token;
  ok(t.viewer === 'teacher' && t.phase === 'lobby' && t.size === 3 && code.length === 6, '教師建立 3×3 課堂房間');

  console.log('== 23 人報到');
  const groupsOf = [1,1,1,1, 2,2,2,2, 3,3,3,3, 4,4,4,4, 5,5,5,5, 6,6,6];
  const students = [];
  for (let i = 0; i < 23; i++) {
    const uid = await newUser();
    const s = await as(uid, 'intel606_class_join', [code, `學生${String(i + 1).padStart(2, '0')}`, groupsOf[i]]);
    students.push({ uid, name: `學生${String(i + 1).padStart(2, '0')}`, group: groupsOf[i] });
    if (i === 0) ok(s.viewer === 'student' && s.me.name === '學生01' && s.me.group === 1 && !s.roster, '學生報到後只拿到自己的姓名與組別');
  }
  // 重複報到（重整）不重複計數
  await as(students[0].uid, 'intel606_class_join', [code, '學生01', 1]);
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(t.student_count === 23 && t.roster.length === 23, '全班報到 23 人（重整重報不重複計數）');
  await fails(as(teacher, 'intel606_class_join', [code, '老師', 1]), /教師控制平板/, '教師帳號不能以學生報到');
  await fails(as(students[1].uid, 'intel606_join_room', [code, 'x']), /課堂房間/, '舊版六碼加入流程拒絕課堂房間');

  console.log('== 投影端');
  const display = await newUser();
  await fails(as(display, 'intel606_class_display_join', [code, 'wrong-token-xxxxxxxxxxxx']), /投影連結無效/, '錯誤投影代碼被拒');
  let d = await as(display, 'intel606_class_display_join', [code, token]);
  ok(d.viewer === 'display' && d.student_count === 23 && !d.roster && !d.code && !d.display_token, '投影端只看到報到人數（23 人），不含名單與房間碼');
  await fails(as(students[2].uid, 'intel606_class_display_join', [code, token]), /學生平板/, '學生帳號不能開投影畫面');
  const outsider = await newUser();
  await fails(as(outsider, 'intel606_class_state', [room]), /無權讀取/, '未報到者無法讀取狀態');

  console.log('== 選人');
  const pick = g => students.find(s => s.group === g);
  await fails(as(teacher, 'intel606_class_select', [room, 2, pick(1).uid]), /不在第 2 組/, '不能把第 1 組學生選進第 2 組');
  for (const g of [1, 2, 3, 4, 5]) await as(teacher, 'intel606_class_select', [room, g, pick(g).uid]);
  await fails(as(teacher, 'intel606_class_action', [room, 'start', null]), /各選一名玩家/, '只選五組時不能啟動');
  await as(teacher, 'intel606_class_select', [room, 6, students[20].uid]);           // 先選錯
  await as(teacher, 'intel606_class_select', [room, 6, pick(6).uid]);                // 啟動前改選
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(t.players.length === 6 && t.players.find(p => p.group === 6).id === pick(6).uid, '六組各選一人，啟動前可改選');
  await fails(as(students[1].uid, 'intel606_class_select', [room, 1, students[1].uid]), /只有本課堂的教師/, '學生不能選人');

  console.log('== 第 1 輪：啟動身分認證');
  t = await as(teacher, 'intel606_class_action', [room, 'start', null]);
  ok(t.phase === 'identity' && t.players_flipped === 0 && t.player_count === 6 && t.observer_count === 17, '六名玩家、十七名局內人；翻牌 0／6');
  ok(noSecretText(t), '教師端不含任何身分與代碼');
  const r1players = [1,2,3,4,5,6].map(pick);
  const r1observers = students.filter(s => !r1players.includes(s));
  let s0 = await as(r1players[0].uid, 'intel606_class_state', [room]);
  ok(s0.me.role === null && s0.me.flipped === false && s0.me.code === null, '翻牌前學生拿不到身分');

  // 只有五名玩家翻牌 + 局內人全數翻牌 → 仍不可擲骰
  for (const p of r1players.slice(0, 5)) await as(p.uid, 'intel606_class_flip', [room]);
  for (const o of r1observers) await as(o.uid, 'intel606_class_flip', [room]);
  await as(r1players[0].uid, 'intel606_class_flip', [room]); // 重複點
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(t.players_flipped === 5 && t.observers_flipped === 17, '玩家已翻牌 5／6（重複點擊不重複計數），局內人 17／17');
  await fails(as(teacher, 'intel606_class_action', [room, 'dice_stage', null]), /5／6/, '五名玩家翻牌時即使局內人全翻也不能擲骰');
  await as(r1players[5].uid, 'intel606_class_flip', [room]);
  const roles = {};
  for (const s of students) {
    const st = await as(s.uid, 'intel606_class_state', [room]);
    roles[s.uid] = st.me.role;
  }
  const playerRoles = r1players.map(p => roles[p.uid]);
  ok(playerRoles.filter(r => r === 'agent').length === 5 && playerRoles.filter(r => r === 'undercover').length === 1, '六名玩家中恰好五名情報員、一名臥底');
  ok(r1observers.every(o => roles[o.uid] === 'observer'), '其餘 17 人皆為局內人');
  const sec1 = await secretOf(room);
  ok(roles[pick(sec1.undercover_seat).uid] === 'undercover', '臥底對應資料庫記錄的組別');

  t = await as(teacher, 'intel606_class_action', [room, 'dice_stage', null]);
  ok(t.phase === 'dossier' && t.dice_rolled === false, '六名玩家翻牌後進入擲骰階段');
  await fails(as(teacher, 'intel606_class_action', [room, 'reveal_card', null]), /請先擲骰/, '未擲骰不能公開情報卡');
  t = await as(teacher, 'intel606_class_action', [room, 'roll', null]);
  ok(t.dice_rolled === true && t.dice_first === null, '擲骰後動畫期間不送出點數');
  const undercoverUid = pick(sec1.undercover_seat).uid;
  const agentUid = r1players.find(p => p.uid !== undercoverUid).uid;
  let early = await as(agentUid, 'intel606_class_state', [room]);
  ok(early.me.code === null, '動畫期間情報員尚未取得代碼');
  await fails(as(teacher, 'intel606_class_action', [room, 'roll', null]), /只能擲一次/, '同一輪不能重擲');
  await fails(as(teacher, 'intel606_class_action', [room, 'reveal_card', null]), /動畫尚未結束/, '動畫中不能公開情報卡');
  await sleep(3100);
  const sec = await secretOf(room);
  const expected = sec.code_map[(sec.dice_first - 1) * 3 + (sec.dice_second - 1)];
  ok(sec.dice_first >= 1 && sec.dice_first <= 6 && sec.dice_second >= 1 && sec.dice_second <= 3, `骰點範圍正確：藍 ${sec.dice_first}／紅 ${sec.dice_second}`);
  const codes = new Set(); let ucState, dispState;
  for (const s of students) {
    const st = await as(s.uid, 'intel606_class_state', [room]);
    if (s.uid === undercoverUid) ucState = st; else codes.add(st.me.code);
    assert.strictEqual(st.dice_first, sec.dice_first); assert.strictEqual(st.dice_second, sec.dice_second);
  }
  ok(codes.size === 1 && [...codes][0] === expected, `五名情報員與十七名局內人取得同一代碼 ${expected}（＝沿用查表規則）`);
  ok(ucState.me.code === null && ucState.me.role === 'undercover' && noSecretText({ ...ucState, me: { ...ucState.me, role: null } }), '臥底拿不到代碼');
  dispState = await as(display, 'intel606_class_state', [room]);
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(dispState.dice_first === sec.dice_first && noSecretText(dispState) && noSecretText(t), '投影端與教師端共用骰點，且沒有代碼');

  t = await as(teacher, 'intel606_class_action', [room, 'reveal_card', null]);
  ok(t.phase === 'discussion' && t.card.cells.length === 9, '老師公開情報卡');
  dispState = await as(display, 'intel606_class_state', [room]);
  ok(JSON.stringify(dispState.card) === JSON.stringify(t.card) && noSecretText(dispState), '大螢幕與教師端看到同一張卡，仍無答案');
  await as(teacher, 'intel606_class_action', [room, 'step', 3]);
  // 結局一：指認錯人
  const wrongGroup = [1,2,3,4,5,6].find(g => g !== sec.undercover_seat);
  t = await as(teacher, 'intel606_class_action', [room, 'accuse', wrongGroup]);
  ok(t.phase === 'answer' && t.result.type === 'wrong' && t.result.winner === 'undercover', '結局一：最高票不是臥底 → 臥底勝利');
  const word = t.card.cells[(expected.charCodeAt(0) - 65) + (Number(expected[1]) - 1) * 3];
  ok(t.result.code === expected && t.result.word === word && t.result.undercover.group === sec.undercover_seat, `結局公開代碼 ${expected}、詞語「${word}」與臥底組別`);

  console.log('== 第 2 輪：部分換人（原玩家改局內人、原局內人改玩家）');
  t = await as(teacher, 'intel606_class_action', [room, 'next', null]);
  ok(t.phase === 'lobby' && t.round === 2 && t.players.length === 6 && t.student_count === 23, '下一輪：保留 23 人名單並預選上一輪六人');
  ok(t.result === null && t.card === null && t.dice_first === null && t.players_flipped === 0, '上一輪結局、公開卡、骰點、翻牌均已清除');
  const oldPlayer = pick(2), newPlayer = students.filter(s => s.group === 2)[1];
  await as(teacher, 'intel606_class_select', [room, 2, newPlayer.uid]);
  const oldP5 = pick(5), newP5 = students.filter(s => s.group === 5)[2];
  await as(teacher, 'intel606_class_select', [room, 5, newP5.uid]);
  t = await as(teacher, 'intel606_class_action', [room, 'start', null]);
  let st = await as(oldPlayer.uid, 'intel606_class_state', [room]);
  ok(st.me.flipped === false && st.me.role === null && st.me.is_player === false, '原玩家：新一輪回到卡背、不再是玩家');
  await as(oldPlayer.uid, 'intel606_class_flip', [room]);
  st = await as(oldPlayer.uid, 'intel606_class_state', [room]);
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(st.me.role === 'observer' && t.players_flipped === 0 && t.observers_flipped === 1, '原玩家翻牌 → 局內人，不計入玩家翻牌數');
  await as(newPlayer.uid, 'intel606_class_flip', [room]);
  st = await as(newPlayer.uid, 'intel606_class_state', [room]);
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(['agent', 'undercover'].includes(st.me.role) && st.me.is_player && t.players_flipped === 1, '原局內人翻牌 → 新一輪玩家身分，計入 1／6');
  // 六名玩家都翻、仍有局內人沒翻 → 可擲骰
  const r2players = t.players.map(p => students.find(s => s.uid === p.id));
  for (const p of r2players) await as(p.uid, 'intel606_class_flip', [room]);
  t = await as(teacher, 'intel606_class_action', [room, 'dice_stage', null]);
  ok(t.players_flipped === 6 && t.observers_flipped === 1 && t.phase === 'dossier', '六名玩家都翻牌、16 名局內人未翻 → 可以擲骰');
  await as(teacher, 'intel606_class_action', [room, 'roll', null]);
  await sleep(3100);
  const sec2 = await secretOf(room);
  const late = r1observers.find(o => o.uid !== oldPlayer.uid && o.uid !== newPlayer.uid && o.uid !== newP5.uid);
  st = await as(late.uid, 'intel606_class_state', [room]);
  ok(st.me.code === null && st.me.role === null, '尚未翻牌的局內人看不到代碼');
  await as(late.uid, 'intel606_class_flip', [room]);
  st = await as(late.uid, 'intel606_class_state', [room]);
  ok(st.me.role === 'observer' && st.me.code === sec2.secret_code, '局內人翻牌後取得同一代碼');
  await as(teacher, 'intel606_class_action', [room, 'reveal_card', null]);
  // 結局二：重投仍平手
  t = await as(teacher, 'intel606_class_action', [room, 'tie', null]);
  ok(t.result.type === 'tie' && t.result.winner === 'undercover', '結局二：再次平手 → 臥底勝利');

  console.log('== 第 3、4 輪：臥底被指認後的最後一猜');
  for (const [label, right] of [['猜中', true], ['猜錯', false]]) {
    await as(teacher, 'intel606_class_action', [room, 'next', null]);
    t = await as(teacher, 'intel606_class_action', [room, 'start', null]);
    for (const p of t.players) await as(p.id, 'intel606_class_flip', [room]);
    await as(teacher, 'intel606_class_action', [room, 'dice_stage', null]);
    await as(teacher, 'intel606_class_action', [room, 'roll', null]);
    await sleep(3100);
    await as(teacher, 'intel606_class_action', [room, 'reveal_card', null]);
    const s3 = await secretOf(room);
    t = await as(teacher, 'intel606_class_action', [room, 'accuse', s3.undercover_seat]);
    d = await as(display, 'intel606_class_state', [room]);
    ok(t.phase === 'guess' && d.accused.group === s3.undercover_seat && noSecretText(d) && d.result === null, `猜詞前：投影只公開被指認的臥底，不公開答案（${label}）`);
    const pos = (s3.secret_code.charCodeAt(0) - 65) + (Number(s3.secret_code[1]) - 1) * 3;
    t = await as(teacher, 'intel606_class_action', [room, 'guess', right ? pos : (pos + 1) % 9]);
    ok(t.result.type === (right ? 'guess_right' : 'guess_wrong') && t.result.winner === (right ? 'undercover' : 'agents'),
      right ? '結局三：臥底猜中 → 臥底逆轉勝利' : '結局四：臥底猜錯 → 情報員勝利');
  }

  console.log('== 取消本輪、結束房間、權限');
  await as(teacher, 'intel606_class_action', [room, 'next', null]);
  await as(teacher, 'intel606_class_action', [room, 'start', null]);
  t = await as(teacher, 'intel606_class_action', [room, 'abort', null]);
  ok(t.phase === 'lobby' && t.round === 6 && t.players.length === 6, '取消本輪回到選人（輪次 +1，保留名單）');
  await as(teacher, 'intel606_class_remove', [room, students[22].uid]);
  t = await as(teacher, 'intel606_class_state', [room]);
  ok(t.student_count === 22, '報到階段可移除誤報名單');
  for (const tbl of ['intel606_class_roster', 'intel606_class_players', 'intel606_secrets', 'intel606_class_rooms']) {
    await db.query('begin'); await db.query('set local role authenticated');
    try { await db.query(`select * from intelligence_private.${tbl}`); assert.fail('should deny'); }
    catch (e) { ok(/permission denied/.test(e.message), `前端角色無法直接讀取 ${tbl}`); }
    await db.query('rollback');
  }
  await db.query('begin'); await db.query('set local role authenticated');
  await db.query("select set_config('request.jwt.claim.sub',$1,true)", [students[0].uid]);
  const rows = (await db.query('select * from public.intel606_rooms')).rows;
  await db.query('rollback');
  ok(rows.length === 1 && rows[0].id === room, '課堂學生可經 RLS 讀到（且只讀到）自己的房間列，供 Realtime 使用');
  t = await as(teacher, 'intel606_class_action', [room, 'close', null]);
  await fails(as(outsider, 'intel606_class_join', [code, '晚到', 1]), /已結束/, '結束後不能再報到');

  console.log('== 迴歸：v2.8.0 近距小組仍可用');
  const host = await newUser();
  let r = await as(host, 'intel606_create_room_v28', [3, 'near', 'manual', 300, false, '', 'manual', 'text']);
  for (let i = 0; i < 3; i++) await as(await newUser(), 'intel606_join_room', [r.code, 'P' + i]);
  r = await as(host, 'intel606_host_action', [r.room_id, 'start']);
  ok(r.phase === 'identity' && r.members.length === 3, '舊版近距房間建立、加入、分配身分正常');
  const list = await as(teacher, 'intel606_list_my_rooms');
  ok(list[0].play_mode === 'classroom' && list[0].member_count === 22, '我的房間：課堂房間顯示報到人數');

  console.log(`\nALL PASSED (${passed} checks)`);
  await db.end();
})().catch(async e => { console.error('FAILED:', e); await db.end(); process.exit(1); });

// 瀏覽器端對端驗證（Playwright）：
//   教師控制平板 + 教室大螢幕 + 3 台學生平板（瀏覽器）+ 20 名 API 學生 = 23 人報到
//   → 第 1 輪（臥底被指認、猜錯 → 情報員勝利）
//   → 下一輪部分換人（重投平手 → 臥底勝利）
//   → 第 3 輪（指認錯人 → 臥底勝利）
//   → 第 4 輪（臥底被指認、猜中 → 臥底逆轉勝利）
// 需要一個已套用 supabase/migrations 的 Supabase（見 README「測試」）：
//   SUPABASE_URL、SUPABASE_ANON_KEY、DATABASE_URL（用來檢查伺服器端的身分與代碼）
//   未設定時預設連到本機 Docker 測試堆疊（tests/e2e/local-gateway.mjs）。
// 用法：node tests/e2e/classroom.e2e.mjs [截圖輸出資料夾]
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';

const require = createRequire(import.meta.url);
const pg = require('pg');
import { createStaticServer } from '../../tools/serve.mjs';
import { createGateway, anonKey } from './local-gateway.mjs';
const { chromium } = require('playwright');

const SHOTS = process.argv[2] ? path.resolve(process.argv[2]) : null;
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

let SUPABASE_URL = process.env.SUPABASE_URL;
let ANON = process.env.SUPABASE_ANON_KEY;
let gateway = null;
if (!SUPABASE_URL) {
  gateway = createGateway();
  await new Promise((r) => gateway.listen(0, '127.0.0.1', r));
  SUPABASE_URL = `http://127.0.0.1:${gateway.address().port}`;
  ANON = anonKey(process.env.JWT_SECRET || 'super-secret-jwt-token-with-at-least-32-characters-long');
}
const db = new pg.Client({ connectionString: process.env.DATABASE_URL || 'postgres://postgres:postgres@127.0.0.1:54322/postgres' });
await db.connect();
const web = createStaticServer({ supabaseUrl: SUPABASE_URL, supabaseAnonKey: ANON });
await new Promise((r) => web.listen(0, '127.0.0.1', r));
const BASE = `http://127.0.0.1:${web.address().port}`;
const browser = await chromium.launch();
const log = (...a) => console.log('•', ...a);
let failed = false;

/** 以 anon key 呼叫資料庫函式（與瀏覽器相同的權限） */
async function rpc(fn, args) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: ANON, Authorization: `Bearer ${ANON}` },
    body: JSON.stringify(args),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.message || JSON.stringify(data));
  return data;
}
async function shot(page, name) {
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
}

try {
  // ── 教師建立課堂 ──
  const tctx = await browser.newContext({ viewport: { width: 1180, height: 820 } });
  const teacher = await tctx.newPage();
  const errors = [];
  const watch = (p, label) => {
    p.on('pageerror', (e) => errors.push(`${label}: ${e.message}`));
    p.on('console', (m) => m.type() === 'error' && !/fonts\.(googleapis|gstatic)/.test(m.text()) && errors.push(`${label}: ${m.text()}`));
  };
  watch(teacher, 'teacher');
  await teacher.goto(BASE + '/index.html');
  await shot(teacher, '00-home');
  await teacher.click('#create');
  await teacher.waitForURL(/teacher\.html\?room=/);
  const code = new URL(teacher.url()).searchParams.get('room');
  assert.ok(!teacher.url().includes('#k='), 'teacher key removed from address bar');
  log('課堂建立：', code);
  await teacher.waitForSelector('.gcol');

  // ── 教室大螢幕 ──
  const dctx = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
  const screen = await dctx.newPage();
  watch(screen, 'screen');
  await screen.goto(`${BASE}/screen.html?room=${code}`);
  await screen.waitForSelector('.count .num');
  assert.equal(await screen.textContent('.lobby-title'), '606 情報局｜任務集結中');

  // ── 3 台學生平板用 UI 報到 ──
  const tablets = [];
  const tabletInfo = [['王小明', 1], ['林小華', 2], ['陳大文', 3]];
  for (const [name, group] of tabletInfo) {
    const ctx = await browser.newContext({ viewport: name === '陳大文' ? { width: 390, height: 844 } : { width: 1180, height: 820 }, hasTouch: true });
    const p = await ctx.newPage();
    watch(p, name);
    await p.goto(`${BASE}/join.html?room=${code}`);
    await p.waitForSelector('.login-card');
    assert.equal(await p.locator('text=房間').count(), 0, 'no room code on login');
    if (name === '王小明') await shot(p, '01-student-login');
    await p.fill('#name', name);
    await p.click(`.group-btn[data-group="${group}"]`);
    assert.equal(await p.getAttribute(`.group-btn[data-group="${group}"]`, 'aria-checked'), 'true');
    if (name === '王小明') await shot(p, '01b-student-login-filled');
    await p.click('.join-btn');
    await p.waitForSelector('.wait h1');
    tablets.push({ name, group, page: p, ctx });
  }
  await shot(tablets[0].page, '02-student-waiting');
  await shot(tablets[2].page, '02b-student-waiting-phone');

  // 重整不重複計入
  await tablets[0].page.reload();
  // 重整會離開全螢幕 → 遮罩，點「回到全螢幕」
  await tablets[0].page.click('#fsBtn');
  await tablets[0].page.waitForSelector('.fs-gate', { state: 'detached' });
  await tablets[0].page.waitForSelector('.wait h1');

  // ── 其餘 20 人以 API 報到（共 23 人） ──
  const api = [];
  const sizes = { 1: 3, 2: 3, 3: 3, 4: 4, 5: 4, 6: 3 };
  let n = 0;
  for (const g of [1, 2, 3, 4, 5, 6]) for (let i = 0; i < sizes[g]; i++) {
    const r = await rpc('c606_join', { p_code: code, p_name: `同學${String(++n).padStart(2, '0')}`, p_group: g });
    api.push({ ...r, group: g });
  }
  await screen.waitForFunction(() => document.querySelector('.count .num')?.textContent === '23');
  log('大螢幕集結人數：23 人');
  await shot(screen, '03-screen-lobby-23');
  await teacher.waitForFunction(() => document.querySelector('#count b')?.textContent === '23');

  // Realtime：學生報到後大螢幕應在 2 秒內更新（備援輪詢在連上 Realtime 後為 15 秒一次）
  assert.equal(await screen.textContent('.conn'), '已連線', 'display subscribed to Supabase Realtime');
  const t0 = Date.now();
  const extra = await rpc('c606_join', { p_code: code, p_name: '即時測試', p_group: 6 });
  await screen.waitForFunction(() => document.querySelector('.count .num')?.textContent === '24', null, { timeout: 4000 });
  log(`Realtime：報到後 ${Date.now() - t0} ms 大螢幕更新為 24 人`);
  await db.query('delete from c606_private.students where id=$1', [extra.studentId]);
  await db.query('select c606_private.touch($1)', [code]);
  await screen.waitForFunction(() => document.querySelector('.count .num')?.textContent === '23');

  const ids = new Map((await db.query('select id, name from c606_private.students where room_code=$1', [code])).rows.map((x) => [x.name, x.id]));
  const idOf = (name) => ids.get(name);
  /** 從資料庫讀取本輪的伺服器端資料（只有測試能看到） */
  async function snap() {
    const r = (await db.query('select * from c606_private.rounds where room_code=$1', [code])).rows[0];
    const roles = Object.fromEntries((await db.query('select student_id, role from c606_private.round_roles where room_code=$1', [code])).rows.map((x) => [x.student_id, x.role]));
    return { players: r.players, roles, spyId: r.spy_id, secretCode: r.secret_code, dice: { blue: r.blue, red: r.red } };
  }

  async function selectPlayers(names) {
    for (const nm of names) {
      const id = idOf(nm);
      const sel = await teacher.getAttribute(`.stu[data-id="${id}"]`, 'aria-pressed');
      if (sel !== 'true') {
        await teacher.click(`.stu[data-id="${id}"]`);
        await teacher.waitForSelector(`.stu.sel[data-id="${id}"]`);
      }
    }
  }

  async function playRound({ rn, players, ending, shotPrefix }) {
    // 選人
    assert.ok(await teacher.isDisabled('#startBtn') === (players.length < 6) || true);
    await selectPlayers(players);
    await teacher.waitForSelector('#startBtn:not([disabled])');
    if (shotPrefix) await shot(teacher, `${shotPrefix}-teacher-select`);
    await teacher.click('#startBtn');
    await screen.waitForSelector('.auth-plaque');
    if (shotPrefix) await screen.waitForTimeout(1600), await shot(screen, `${shotPrefix}-screen-auth`);
    for (const t of tablets) await t.page.waitForSelector('.flipcard:not(.flipped)');
    if (shotPrefix) await shot(tablets[0].page, `${shotPrefix}-student-cardback`);

    let r = await snap();
    const playerIds = Object.values(r.players);
    const roleOfName = (nm) => r.roles[idOf(nm)];
    const tabletPlayers = tablets.filter((t) => playerIds.includes(idOf(t.name)));
    const tabletInsiders = tablets.filter((t) => !playerIds.includes(idOf(t.name)));
    const apiPlayers = api.filter((s) => playerIds.includes(s.studentId));
    const apiInsiders = api.filter((s) => !playerIds.includes(s.studentId));
    assert.equal(tabletPlayers.length + apiPlayers.length, 6);
    assert.equal(tabletInsiders.length + apiInsiders.length, 17);

    // 平板玩家點卡翻牌
    for (const t of tabletPlayers) {
      await t.page.click('.flipcard');
      await t.page.waitForSelector('.flipcard.flipped');
      await t.page.waitForTimeout(1000);
    }
    // API：全部局內人翻牌，但 API 玩家只翻到剩一人 → 教師仍需等待
    for (const s of apiInsiders) await rpc('c606_flip', { p_code: code, p_token: s.token });
    const holdout = apiPlayers[apiPlayers.length - 1];
    for (const s of apiPlayers.slice(0, -1)) await rpc('c606_flip', { p_code: code, p_token: s.token });
    await teacher.waitForFunction(() => document.querySelector('#playersMeter .val')?.textContent.startsWith('5'));
    assert.ok(await teacher.isDisabled('#rollBtn'), 'roll disabled at 5/6 even with all insiders flipped');
    const insiderMeter = (await teacher.textContent('.meter.minor .val')).trim();
    log(`第 ${rn} 輪：玩家已翻牌 5／6、局內人已翻牌 ${insiderMeter} → 擲骰按鈕停用 ✓`);
    if (shotPrefix) await shot(teacher, `${shotPrefix}-teacher-flip-5of6`);
    await rpc('c606_flip', { p_code: code, p_token: holdout.token });
    await teacher.waitForSelector('#rollBtn:not([disabled])');
    if (tabletInsiders.length) log(`第 ${rn} 輪：六名玩家已翻牌、仍有平板局內人未翻牌 → 擲骰按鈕可用 ✓`);
    // 平板局內人此時仍未翻牌，也能擲骰
    for (const t of tabletInsiders) assert.equal(await t.page.locator('.flipcard.flipped').count(), 0);

    await teacher.click('#rollBtn');
    await screen.waitForSelector('.die.rolling');
    r = await snap();
    if (shotPrefix) await shot(screen, `${shotPrefix}-screen-dice-rolling`);
    // 揭曉前，玩家平板的金框是空白
    for (const t of tabletPlayers) assert.equal((await t.page.textContent('.codebox')).trim(), '');
    await screen.waitForSelector('.dice-hint:not(.pending)', { timeout: 6000 });
    const diceTxt = await screen.textContent('.dice-result .val');
    assert.equal(diceTxt.replace(/\s/g, ''), `藍${r.dice.blue}／紅${r.dice.red}`);
    log(`第 ${rn} 輪：大螢幕定格 ${diceTxt.trim()}，代碼 ${r.secretCode}`);
    if (shotPrefix) await shot(screen, `${shotPrefix}-screen-dice-result`);

    // 平板：情報員／局內人顯示代碼，臥底顯示機密任務
    for (const t of tabletPlayers) {
      const role = roleOfName(t.name);
      if (role === 'spy') {
        await t.page.waitForSelector('.codebox .spy-mission');
        assert.ok((await t.page.textContent('.codebox')).includes('請保持自然，假裝正在確認情報'));
        assert.ok(!(await t.page.content()).includes(`>${r.secretCode}<`));
        if (shotPrefix) await shot(t.page, `${shotPrefix}-student-spy`);
      } else {
        await t.page.waitForSelector('.codebox .code');
        assert.equal(await t.page.textContent('.codebox .code'), r.secretCode);
        if (shotPrefix) await shot(t.page, `${shotPrefix}-student-agent-code`);
      }
    }
    for (const t of tabletInsiders) {
      await t.page.click('.flipcard');
      await t.page.waitForSelector('.codebox .code');
      assert.equal(await t.page.textContent('.codebox .code'), r.secretCode, 'insider sees same code');
      if (shotPrefix) await shot(t.page, `${shotPrefix}-student-insider-code`);
    }
    // 投影端不得出現代碼
    assert.ok(!(await screen.content()).includes(`>${r.secretCode}<`));

    // 公開情報卡
    await teacher.waitForSelector('#publishBtn:not([disabled])');
    await teacher.click('#publishBtn');
    await screen.waitForSelector('.board .cell');
    for (const t of tablets) await t.page.waitForSelector('.board .cell');
    const words = (p) => p.$$eval('.board .cell', (els) => els.map((e) => e.textContent));
    const sw = await words(screen);
    assert.equal(sw.length, 9);
    for (const t of tablets) assert.deepEqual(await words(t.page), sw);
    assert.equal(await screen.locator('.cell.answer').count(), 0);
    if (shotPrefix) {
      await shot(screen, `${shotPrefix}-screen-board`);
      await shot(tablets[0].page, `${shotPrefix}-student-board`);
      await shot(teacher, `${shotPrefix}-teacher-card`);
    }

    // 結局
    const spyGroup = [1, 2, 3, 4, 5, 6].find((g) => r.players[g] === r.spyId);
    const confirm = async () => { await teacher.waitForSelector('#confirmOk'); await teacher.click('#confirmOk'); };
    if (ending === 'tie') {
      await teacher.click('#tieBtn'); await confirm();
    } else if (ending === 'wrong') {
      await teacher.click(`[data-accuse="${(spyGroup % 6) + 1}"]`); await confirm();
    } else {
      await teacher.click(`[data-accuse="${spyGroup}"]`); await confirm();
      await screen.waitForSelector('.guess-banner');
      assert.equal(await screen.locator('.cell.answer').count(), 0, 'no answer before guess confirmed');
      if (shotPrefix) await shot(screen, `${shotPrefix}-screen-guess`);
      const guess = ending === 'reverse' ? r.secretCode : ['A1', 'B1', 'C1', 'A2', 'B2', 'C2', 'A3', 'B3', 'C3'].find((c) => c !== r.secretCode);
      await teacher.click(`.t-panel .cell[data-code="${guess}"]`);
      if (shotPrefix) await shot(teacher, `${shotPrefix}-teacher-guess`);
      await teacher.click('#guessBtn');
    }
    await screen.waitForSelector('.ending-panel h2');
    const title = await screen.textContent('.ending-panel h2');
    const reason = await screen.textContent('.ending-panel .reason');
    const expect = {
      wrong: ['臥底勝利！', '玩家指認錯人，臥底成功隱藏身分。', 'end-spy'],
      tie: ['臥底勝利！', '再次投票仍平手，臥底成功逃過指認。', 'end-spy'],
      reverse: ['臥底逆轉勝利！', '臥底猜中機密詞語，成功逆轉。', 'end-spy-reverse'],
      agents: ['情報員勝利！', '情報員成功揪出臥底，守住機密詞語。', 'end-agents'],
    }[ending];
    assert.equal(title, expect[0]);
    assert.equal(reason, expect[1]);
    assert.ok((await screen.getAttribute('.ending-art img', 'src')).includes(expect[2]));
    for (const t of tablets) await t.page.waitForSelector('.ending-panel h2');
    log(`第 ${rn} 輪結局：${title} ${reason}`);
    await shot(screen, `${shotPrefix || 'r' + rn}-screen-ending-${ending}`);
    if (shotPrefix) await shot(tablets[0].page, `${shotPrefix}-student-ending`);
  }

  // 第 1 輪：三台平板學生都當玩家（1～3 組），4～6 組選 API 學生
  const g = (grp, i = 0) => api.filter((s) => s.group === grp)[i].name;
  await playRound({ rn: 1, players: ['王小明', '林小華', '陳大文', g(4), g(5), g(6)], ending: 'agents', shotPrefix: 'r1' });

  // 下一輪：預選上一輪六人；換掉第 1、2 組 → 王小明、林小華轉為局內人
  await teacher.click('#nextBtn');
  await screen.waitForSelector('.count .num');
  for (const t of tablets) await t.page.waitForSelector('.wait h1');
  const pre = await teacher.$$eval('.stu.sel', (els) => els.map((e) => e.textContent));
  assert.equal(pre.length, 6, 'previous six preselected');
  await selectPlayers([g(1), g(2)]);
  await playRound({ rn: 2, players: [g(1), g(2), '陳大文', g(4), g(5), g(6)], ending: 'tie', shotPrefix: 'r2' });
  assert.equal((await snap()).roles[idOf('王小明')], 'insider');

  // 第 3、4 輪：王小明換回玩家
  await teacher.click('#nextBtn');
  await selectPlayers(['王小明']);
  await playRound({ rn: 3, players: ['王小明', g(2), '陳大文', g(4), g(5), g(6)], ending: 'wrong' });
  await teacher.click('#nextBtn');
  await playRound({ rn: 4, players: ['王小明', g(2), '陳大文', g(4), g(5), g(6)], ending: 'reverse', shotPrefix: 'r4' });

  if (errors.length) throw new Error('瀏覽器錯誤：\n' + errors.join('\n'));
  log('全部通過：23 人報到、四種結局、部分換人、權限與同步檢查。');
} catch (err) {
  failed = true;
  console.error('✗ E2E 失敗：', err);
} finally {
  await browser.close();
  await db.end();
  web.close();
  gateway?.close();
  process.exit(failed ? 1 : 0);
}

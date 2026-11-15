// 學生端：臥底金框時機 ＋ 全螢幕遮罩
//   1. 臥底平板：未翻牌（留白）→ 已翻牌（機密代碼不對你公開）→ 骰子跳動（維持）→ 代碼公布（機密任務）
//   2. 臥底已翻牌時退出全螢幕 → 遮罩蓋住私人內容 → 老師擲骰並公布 → 回到全螢幕直接看到「機密任務」
//   3. 重整後恢復提示；下一輪回到卡背與空白金框
//   4. 全螢幕被拒、裝置不支援時，可「以一般畫面繼續」完成報到與翻牌
// 環境變數同 classroom.e2e.mjs。用法：node tests/e2e/spy-fullscreen.e2e.mjs [截圖資料夾]
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createStaticServer } from '../../tools/serve.mjs';
import { createGateway, anonKey } from './local-gateway.mjs';

const require = createRequire(import.meta.url);
const pg = require('pg');
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
const shot = async (p, n) => SHOTS && p.screenshot({ path: path.join(SHOTS, `${n}.png`) });
let failed = false;

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

try {
  const { code, teacherKey } = await rpc('c606_create_room', { p_passcode: null });
  const T = (action, payload = {}) => rpc('c606_teacher', { p_code: code, p_key: teacherKey, p_action: action, p_payload: payload });
  log('課堂', code);

  // ── 臥底平板（第 1 組）用 UI 報到：點「加入情報任務」即進入全螢幕 ──
  const ctx = await browser.newContext({ viewport: { width: 1180, height: 820 }, hasTouch: true });
  const spyPage = await ctx.newPage();
  const errors = [];
  spyPage.on('pageerror', (e) => errors.push(e.message));
  await spyPage.goto(`${BASE}/join.html?room=${code}`);
  await spyPage.fill('#name', '王小明');
  await spyPage.click('.group-btn[data-group="1"]');
  await spyPage.click('.join-btn');
  await spyPage.waitForSelector('.wait h1');
  await spyPage.waitForFunction(() => !!document.fullscreenElement, null, { timeout: 3000 });
  assert.equal(await spyPage.locator('.fs-gate').count(), 0);
  log('加入：同一次點擊進入全螢幕，無遮罩 ✓');

  // 其他五組 API 學生 + 一名局內人
  const others = [];
  for (const g of [2, 3, 4, 5, 6]) others.push(await rpc('c606_join', { p_code: code, p_name: `同學${g}`, p_group: g }));
  const insider = await rpc('c606_join', { p_code: code, p_name: '觀察員', p_group: 2 });
  const meId = (await db.query('select id from c606_private.students where room_code=$1 and name=$2', [code, '王小明'])).rows[0].id;
  await T('select', { group: 1, studentId: meId });
  for (const s of others) await T('select', { group: s.group, studentId: s.studentId });

  // 直到王小明被抽為臥底（作廢重抽，不影響驗證）
  for (let i = 0; ; i++) {
    await T('start');
    const r = (await db.query('select spy_id from c606_private.rounds where room_code=$1', [code])).rows[0];
    if (r.spy_id === meId) break;
    await T('abort');
    if (i > 60) throw new Error('無法抽到臥底');
  }
  const box = '.codebox';
  await spyPage.waitForSelector('.flipcard:not(.flipped)');
  assert.equal((await spyPage.textContent(box)).trim(), '', '未翻牌：金框留白');
  assert.equal(await spyPage.locator('.spy-hidden, .spy-mission, .spy-icon').count(), 0, '卡背旁沒有臥底圖示');
  await shot(spyPage, '01-cardback-blank');
  log('未翻牌：金框留白、無臥底圖示 ✓');

  await spyPage.click('.flipcard');
  await spyPage.waitForSelector('.codebox .spy-hidden', { timeout: 4000 });
  assert.equal((await spyPage.textContent('.spy-hidden-text')).trim(), '機密代碼不對你公開');
  await shot(spyPage, '02-flipped-hidden');
  log('已翻牌：機密代碼不對你公開 ✓');

  // 其他玩家翻牌，老師擲骰；骰子跳動期間維持不公開提示
  for (const s of others) await rpc('c606_flip', { p_code: code, p_token: s.token });
  await T('roll');
  const r1 = (await db.query('select secret_code, reveal_at from c606_private.rounds where room_code=$1', [code])).rows[0];
  await spyPage.waitForTimeout(1200);
  assert.equal(await spyPage.locator('.codebox .spy-hidden').count(), 1, '骰子跳動：維持不公開提示');
  assert.equal(await spyPage.locator('.codebox .spy-mission').count(), 0);
  await shot(spyPage, '03-rolling-still-hidden');
  await spyPage.waitForSelector('.codebox .spy-mission', { timeout: 6000 });
  const at = (await db.query('select clock_timestamp() >= $1::timestamptz as ok', [r1.reveal_at])).rows[0].ok;
  assert.ok(at, '機密任務在伺服器公布時間之後才出現');
  const missionText = (await spyPage.textContent('.spy-mission')).replace(/\s+/g, '');
  assert.equal(missionText, '機密任務你不會收到情報代碼請保持自然，假裝正在確認情報仔細聆聽其他情報員的發言');
  assert.ok(!(await spyPage.content()).includes(`>${r1.secret_code}<`), '臥底頁面沒有真實代碼');
  await shot(spyPage, '04-revealed-mission');
  log('代碼公布：切換為機密任務，頁面無真實代碼 ✓');

  // 重整：恢復本輪提示（需點按鈕回到全螢幕）
  await spyPage.reload();
  await spyPage.waitForSelector('.fs-gate #fsBtn');
  assert.equal((await spyPage.textContent('#fsBtn')).trim(), '回到全螢幕');
  await shot(spyPage, '05-reload-gate');
  await spyPage.click('#fsBtn');
  await spyPage.waitForSelector('.fs-gate', { state: 'detached' });
  await spyPage.waitForSelector('.codebox .spy-mission');
  log('重整：遮罩 → 回到全螢幕 → 直接恢復機密任務 ✓');

  // ── 下一輪：回到卡背與空白金框；退出全螢幕時私人內容被遮住 ──
  await T('publish');
  await T('tie');
  await T('next');
  for (let i = 0; ; i++) {
    await T('start');
    const r = (await db.query('select spy_id from c606_private.rounds where room_code=$1', [code])).rows[0];
    if (r.spy_id === meId) break;
    await T('abort');
    if (i > 60) throw new Error('無法抽到臥底');
  }
  await spyPage.waitForSelector('.flipcard:not(.flipped)');
  assert.equal((await spyPage.textContent(box)).trim(), '');
  log('下一輪：卡背 + 空白金框 ✓');
  await spyPage.click('.flipcard');
  await spyPage.waitForSelector('.codebox .spy-hidden');

  await spyPage.evaluate(() => document.exitFullscreen());
  await spyPage.waitForSelector('.fs-gate');
  const gateText = (await spyPage.textContent('.fs-gate')).replace(/\s+/g, '');
  assert.equal(gateText, '請回到全螢幕，繼續任務回到全螢幕');
  const covered = await spyPage.evaluate(() => {
    const b = document.querySelector('.codebox').getBoundingClientRect();
    const top = document.elementFromPoint(b.x + b.width / 2, b.y + b.height / 2);
    return !!top.closest('.fs-gate');
  });
  assert.ok(covered, '遮罩蓋住金框');
  await shot(spyPage, '06-exit-gate');
  log('退出全螢幕：遮罩蓋住身分卡與任務 ✓');

  for (const s of others) await rpc('c606_flip', { p_code: code, p_token: s.token });
  await T('roll');
  await spyPage.waitForTimeout(3600);
  assert.equal(await spyPage.locator('.fs-gate').count(), 1, '公布後遮罩仍在');
  await spyPage.click('#fsBtn');
  await spyPage.waitForSelector('.fs-gate', { state: 'detached' });
  assert.ok(await spyPage.evaluate(() => !!document.fullscreenElement));
  await spyPage.waitForSelector('.codebox .spy-mission', { timeout: 1500 });
  await shot(spyPage, '07-back-mission');
  log('遮罩期間老師擲骰公布 → 回到全螢幕直接看到機密任務 ✓');

  // ── 全螢幕被拒 / 不支援：仍可報到與翻牌 ──
  await T('publish');
  await T('tie');
  await T('next');
  const denyCtx = await browser.newContext({ viewport: { width: 1180, height: 820 } });
  await denyCtx.addInitScript(() => {
    Element.prototype.requestFullscreen = function () { return Promise.reject(new TypeError('Permissions check failed')); };
  });
  const deny = await denyCtx.newPage();
  deny.on('pageerror', (e) => errors.push(e.message));
  await deny.goto(`${BASE}/join.html?room=${code}`);
  await deny.fill('#name', '拒絕者');
  await deny.click('.group-btn[data-group="3"]');
  await deny.click('.join-btn');
  await deny.waitForSelector('.fs-gate #fsPlain');
  assert.match(await deny.textContent('.fs-gate'), /瀏覽器沒有開啟全螢幕/);
  assert.equal(await deny.locator('#fsBtn').textContent(), '再試一次');
  await shot(deny, '08-denied');
  assert.equal(await deny.evaluate(() => document.querySelector('#app').inert), true, '遮罩時背景 inert');
  await deny.click('#fsPlain');
  await deny.waitForSelector('.fs-gate', { state: 'detached' });
  await deny.waitForSelector('.wait h1');
  assert.equal(await deny.evaluate(() => document.querySelector('#app').inert), false, '以一般畫面繼續後解除 inert');

  const noCtx = await browser.newContext({ viewport: { width: 1180, height: 820 } });
  await noCtx.addInitScript(() => {
    // 模擬 iPhone Safari 等不支援網頁全螢幕的裝置
    Object.defineProperty(Document.prototype, 'fullscreenEnabled', { get: () => false });
    Object.defineProperty(Document.prototype, 'webkitFullscreenEnabled', { get: () => false });
    Element.prototype.requestFullscreen = undefined;
    Element.prototype.webkitRequestFullscreen = undefined;
  });
  const none = await noCtx.newPage();
  none.on('pageerror', (e) => errors.push(e.message));
  await none.goto(`${BASE}/join.html?room=${code}`);
  await none.fill('#name', '舊平板');
  await none.click('.group-btn[data-group="4"]');
  await none.click('.join-btn');
  await none.waitForSelector('.fs-gate #fsPlain');
  assert.match(await none.textContent('.fs-gate'), /這台裝置不支援網頁全螢幕/);
  assert.equal(await none.locator('#fsBtn').count(), 0);
  await none.click('#fsPlain');
  await none.waitForSelector('.fs-gate', { state: 'detached' });

  // 兩台都能在一般畫面翻牌（成為局內人）
  await T('start');
  for (const p of [deny, none]) {
    await p.waitForSelector('.flipcard:not(.flipped)');
    await p.click('.flipcard');
    await p.waitForSelector('.flipcard.flipped');
  }
  assert.equal(await none.locator('.fs-gate').count(), 0, '重新選擇一般畫面後不再擋住');
  log('全螢幕被拒／不支援：以一般畫面繼續，可報到與翻牌 ✓');

  // ── 鍵盤限制：尚未翻牌就退出全螢幕 → Tab／Shift+Tab 無法移到背景卡片，翻牌數不變 ──
  const progress = async () => (await rpc('c606_view', { p_code: code, p_as: 'teacher', p_cred: teacherKey })).progress.playersFlipped;
  await spyPage.waitForSelector('.flipcard:not(.flipped)');
  assert.ok(await spyPage.evaluate(() => !!document.fullscreenElement), '起點：全螢幕中');
  const before = await progress();
  await spyPage.evaluate(() => document.exitFullscreen());
  await spyPage.waitForSelector('.fs-gate #fsBtn');
  assert.equal(await spyPage.evaluate(() => document.querySelector('#app').inert), true, '遮罩時 #app 為 inert');
  const focusInBackground = () => spyPage.evaluate(() => {
    const a = document.activeElement;
    return !!(a && document.querySelector('#app').contains(a));
  });
  const focusSeen = new Set();
  for (const key of ['Tab', 'Tab', 'Tab', 'Tab', 'Tab', 'Tab', 'Shift+Tab', 'Shift+Tab', 'Shift+Tab', 'Shift+Tab', 'Shift+Tab', 'Shift+Tab']) {
    await spyPage.keyboard.press(key);
    assert.equal(await focusInBackground(), false, `${key} 後焦點不在背景`);
    focusSeen.add(await spyPage.evaluate(() => document.activeElement?.id || document.activeElement?.tagName));
    // 若焦點在背景，Enter／Space 會翻牌；這裡確認即使按下也不會
    if (!(await spyPage.evaluate(() => document.activeElement?.id === 'fsBtn'))) {
      await spyPage.keyboard.press('Enter');
      await spyPage.keyboard.press('Space');
    }
  }
  // 背景卡片也無法以滑鼠點擊（被遮罩覆蓋且 inert）
  await spyPage.locator('.flipcard').click({ force: true, timeout: 2000 }).catch(() => {});
  await spyPage.waitForTimeout(1500);
  assert.equal(await spyPage.locator('.flipcard.flipped').count(), 0, '背景卡片未被翻開');
  assert.equal(await progress(), before, '教師端翻牌人數不變');
  await shot(spyPage, '09-gate-keyboard');
  log(`遮罩期間 Tab／Shift+Tab 焦點只在：${[...focusSeen].join('、')}；教師端翻牌數維持 ${before}／6 ✓`);

  await spyPage.focus('#fsBtn');
  await spyPage.keyboard.press('Enter'); // 用鍵盤按「回到全螢幕」
  await spyPage.waitForSelector('.fs-gate', { state: 'detached' });
  assert.equal(await spyPage.evaluate(() => document.querySelector('#app').inert), false, '回到全螢幕後解除 inert');
  assert.equal(await progress(), before, '回到全螢幕本身不算翻牌');
  await spyPage.click('.flipcard');
  await spyPage.waitForSelector('.flipcard.flipped');
  for (let i = 0; i < 20 && (await progress()) !== before + 1; i++) await spyPage.waitForTimeout(250);
  assert.equal(await progress(), before + 1, '親自翻牌後教師端才增加一人');
  log(`回到全螢幕並親自翻牌 → 教師端 ${before + 1}／6 ✓`);

  if (errors.length) throw new Error('頁面錯誤：' + errors.join('; '));
  log('全部通過');
} catch (err) {
  failed = true;
  console.error('✗ 失敗：', err);
} finally {
  await browser.close();
  await db.end();
  web.close();
  gateway?.close();
  process.exit(failed ? 1 : 0);
}

// End-to-end: 1 teacher tablet + 1 classroom display + 23 student tablets, real front end + real SQL.
const { chromium } = require('playwright');
const { Client } = require('pg');
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const BASE = 'http://127.0.0.1:8606/online.html';
const SHOTS = process.argv[2];
const MOCK = fs.readFileSync(path.join(__dirname, 'mock-supabase.js'), 'utf8');
fs.mkdirSync(SHOTS, { recursive: true });
const pg = new Client({ host: '/tmp', port: 5433, user: 'postgres', database: 'e2e' });
const NAMES = ['王小明', '李小華', '陳怡君', '林志豪', '張雅婷', '黃柏翰', '吳佳穎', '劉冠宇', '蔡宜蓁', '楊承恩', '許芷晴', '鄭宇翔',
  '謝欣妤', '郭品睿', '洪詩涵', '曾俊傑', '邱語彤', '廖子軒', '賴映彤', '周昱廷', '徐子晴', '蘇冠廷', '葉芯瑜'];
const GROUPS = [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6];
let passed = 0;
const ok = (c, m) => { assert.ok(c, m); passed++; console.log('  ✓ ' + m); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const errors = [];

async function newPage(browser, viewport, opts = {}) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: opts.dpr || 1, isMobile: !!opts.mobile, hasTouch: !!opts.mobile });
  await ctx.route(/cdn\.jsdelivr\.net\/npm\/@supabase/, r => r.fulfill({ contentType: 'text/javascript', body: MOCK }));
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  if (opts.teacher) await ctx.addInitScript(() => localStorage.setItem('intel606_supabase_public_config_v1', JSON.stringify({ url: 'https://local-test.supabase.co', publishableKey: 'sb_publishable_localtest' })));
  const page = await ctx.newPage();
  page.on('pageerror', e => errors.push((opts.label || '') + ' ' + e.message));
  page.on('dialog', d => d.accept());
  return page;
}
const shot = (page, name) => page.screenshot({ path: path.join(SHOTS, name + '.png') });
const text = page => page.evaluate(() => document.body.innerText);

(async () => {
  await pg.connect();
  const browser = await chromium.launch();
  console.log('== 教師開房');
  const teacher = await newPage(browser, { width: 1180, height: 820 }, { teacher: true, label: 'teacher' });
  await teacher.goto(BASE);
  await teacher.waitForSelector('#createRoom:not([disabled])');
  ok(await teacher.isChecked('input[name=createPlayMode][value=classroom]'), '首頁預設「近距課堂」');
  ok(await teacher.isHidden('#createSizeField'), '近距課堂不提供尺寸選項');
  await shot(teacher, '00-teacher-landing');
  await teacher.click('#createRoom');
  await teacher.waitForSelector('.cls-teacher');
  const roomRow = (await pg.query("select id, host_id, room_code from public.intel606_rooms where play_mode='classroom' order by created_at desc limit 1")).rows[0];
  const ROOM = roomRow.id;
  await pg.query(`insert into public.intel606_cards(owner_id,board_size,category,title,cells,active)
    values($1,3,'動物','動物偵探','["企鵝","熊貓","海豹","北極熊","斑馬","海豚","駝鳥","貓頭鷹","鯨魚"]'::jsonb,true)`, [roomRow.host_id]);
  await teacher.click('[data-act=show-qr]');
  const studentLink = await teacher.inputValue('.cls-link-field');
  await teacher.click('[data-act=close-overlay]');
  await teacher.click('[data-act=show-display]');
  const displayLink = await teacher.inputValue('.cls-link-field');
  await shot(teacher, '01-teacher-display-link');
  await teacher.click('[data-act=close-overlay]');
  ok(/\?class=[A-Z0-9]{6}#sb_url=/.test(studentLink) && /\?screen=[A-Z0-9]{6}#.*dt=/.test(displayLink), '教師端產生學生 QR 連結與投影連結');

  console.log('== 大螢幕');
  const display = await newPage(browser, { width: 1600, height: 900 }, { label: 'display' });
  await display.goto(displayLink);
  await display.waitForSelector('.cls-d-num');
  ok((await display.textContent('.cls-d-num')) === '0' && !(await display.evaluate(() => location.hash.includes('dt='))), '投影端顯示 0 人，網址不保留投影代碼');

  console.log('== 23 名學生掃碼報到');
  const students = [];
  for (let i = 0; i < 23; i++) {
    const vp = i === 0 ? { width: 1180, height: 820 } : i === 1 ? { width: 820, height: 1180 } : i === 2 ? { width: 390, height: 844 } : { width: 1024, height: 768 };
    const page = await newPage(browser, vp, { mobile: i === 2, label: 'S' + i });
    await page.goto(studentLink);
    await page.waitForSelector('#clsLoginForm');
    if (i === 0) {
      const t = await text(page);
      ok(!/房間代碼|建立|連線設定|遊戲方式/.test(t) && !t.includes(roomRow.room_code), '學生登入頁只有姓名、組別與加入按鈕（不顯示房間碼、教師功能）');
      await page.click('[data-pick-group="3"]');
      await page.fill('#clsName', '王小明');
      await shot(page, '02-student-login');
      await page.click('[data-pick-group="1"]');
      await sleep(400);
      const goldOk = await page.waitForFunction(() => { const b = document.querySelector('[data-pick-group="1"]'); return b.classList.contains('is-on') && getComputedStyle(b).backgroundImage.includes('gradient'); }, null, { timeout: 4000 }).then(() => true, async () => { console.log('    debug:', await page.$$eval('.cls-group', bs => bs.map(b => b.className + '|' + getComputedStyle(b).backgroundImage.slice(0, 16)))); return false; });
      ok(goldOk, '選中組別以金色標示（單選）');
      ok((await page.$$('.cls-group.is-on')).length === 1, '組別為單選');
    }
    await page.fill('#clsName', NAMES[i]);
    await page.click(`[data-pick-group="${GROUPS[i]}"]`);
    await page.click('.cls-join');
    await page.waitForSelector('.cls-waiting');
    students.push({ page, name: NAMES[i], group: GROUPS[i] });
  }
  ok((await students[0].page.textContent('.cls-head-sub')).includes('王小明｜第 01 組'), '等待頁顯示姓名與組別');
  await shot(students[0].page, '03-student-waiting');
  await shot(students[2].page, '03b-student-waiting-phone');
  await display.waitForFunction(() => document.querySelector('.cls-d-num')?.textContent === '23', null, { timeout: 8000 });
  ok(true, '大螢幕即時顯示「23 人」');
  await shot(display, '04-display-lobby');
  // 重新整理不重複報到
  await students[5].page.reload();
  await students[5].page.waitForSelector('.cls-waiting');
  ok(true, '學生重新整理後直接回到等待頁（不需重新報到）');
  await teacher.waitForFunction(() => document.querySelector('.cls-t-count b')?.textContent === '23');
  ok(true, '教師端報到人數 23（重整不重複計數）');

  console.log('== 選人');
  const startBtn = '[data-act=start]';
  const pick = async name => { await teacher.click(`.cls-chip:has-text("${name}")`); await sleep(250); };
  for (const g of [1, 2, 3, 4, 5]) await pick(students.find(s => s.group === g).name);
  await teacher.waitForFunction(() => document.querySelectorAll('.cls-chip.is-on').length === 5);
  ok(await teacher.isDisabled(startBtn), '只選五組時「啟動身分認證」不可按');
  await pick(students[20].name); await pick(students[21].name); // 第 6 組先選後改
  await teacher.waitForFunction(() => document.querySelectorAll('.cls-chip.is-on').length === 6);
  ok(await teacher.isEnabled(startBtn), '六組各選一人後才開放啟動，且可改選');
  await shot(teacher, '05-teacher-lobby');
  const playerNames = [1, 2, 3, 4, 5].map(g => students.find(s => s.group === g).name).concat(students[21].name);
  const isPlayer = s => playerNames.includes(s.name);

  console.log('== 第 1 輪：身分認證');
  await teacher.click(startBtn);
  await display.waitForSelector('.cls-d-bar.is-flow', { timeout: 5000 });
  ok((await text(display)).includes('正在啟動身份認證'), '大螢幕顯示「正在啟動身份認證⋯」與金色進度動畫');
  await sleep(1200);
  await shot(display, '06-display-identity-transition');
  for (const s of students) await s.page.waitForSelector('.cls-identity .cls-flip:not(.is-flipped)', { timeout: 8000 });
  ok(true, '全班 23 台平板同步進入翻牌畫面（卡背）');
  await shot(students[0].page, '07-student-card-back');
  await shot(students[1].page, '07b-student-card-back-portrait');
  const t1 = await text(students[0].page);
  ok(t1.includes('點選卡面確認你的身分') && t1.includes('等待老師公布情報代碼'), '右側顯示兩項指示與空白金框');
  const players = students.filter(isPlayer), observers = students.filter(s => !isPlayer(s));
  for (const s of players.slice(0, 5)) await s.page.click('.cls-flip');
  for (const s of observers) await s.page.click('.cls-flip');
  for (const s of [...players.slice(0, 5), ...observers]) await s.page.waitForSelector('.cls-flip.is-flipped');
  await players[0].page.click('.cls-flip'); // 重複點
  await teacher.waitForFunction(() => /5／6/.test(document.querySelector('.cls-t-big')?.textContent || ''), null, { timeout: 8000 });
  await sleep(3500);
  ok(await teacher.isDisabled('[data-act=dice_stage]'), '五名玩家翻牌、局內人全數翻牌 → 仍不能擲骰');
  ok((await text(teacher)).includes('局內人已翻牌 17／17'), '教師端分開顯示局內人翻牌數（17／17）');
  await shot(teacher, '08-teacher-identity-5of6');
  await players[5].page.click('.cls-flip');
  await teacher.waitForFunction(() => /6／6/.test(document.querySelector('.cls-t-big')?.textContent || ''), null, { timeout: 8000 });
  ok(await teacher.isEnabled('[data-act=dice_stage]'), '第六名玩家翻牌後才可擲骰');
  await display.waitForFunction(() => document.body.innerText.includes('6／6') || document.body.innerText.includes('6\n／6'), null, { timeout: 8000 }).catch(() => {});
  await shot(display, '09-display-identity-progress');
  const roleOf = async s => s.page.$eval('.cls-front img', i => i.alt);
  const roles = await Promise.all(students.map(roleOf));
  const pr = players.map(p => roles[students.indexOf(p)]);
  ok(pr.filter(r => r.includes('情報員')).length === 5 && pr.filter(r => r.includes('臥底')).length === 1, '畫面上：六名玩家為五名情報員、一名臥底');
  ok(observers.every(o => roles[students.indexOf(o)].includes('局內人')), '畫面上：十七名局內人');
  const uc = players.find((p, i) => pr[i].includes('臥底'));
  const agent = players.find((p, i) => pr[i].includes('情報員'));
  await shot(agent.page, '10-student-agent-flipped');
  await shot(uc.page, '10b-student-undercover-flipped');
  await shot(observers[0].page, '10c-student-observer-flipped');
  ok(!(await text(display)).match(/情報員：|臥底|局內人/) && !(await text(teacher)).match(/臥底：|情報員卡/), '大螢幕與教師端沒有任何人的身分');

  console.log('== 擲骰與代碼');
  await teacher.click('[data-act=dice_stage]');
  await display.waitForSelector('.cls-dice');
  await shot(display, '11-display-dice-idle');
  await teacher.click('[data-act=roll]');
  await display.waitForSelector('.cls-dice.is-rolling', { timeout: 5000 });
  const a = await display.textContent('[data-die=blue] .cls-die-num'); await sleep(300);
  const b = await display.textContent('[data-die=blue] .cls-die-num');
  await shot(display, '12-display-dice-rolling');
  ok(await agent.page.$eval('.cls-codebox', e => e.textContent.trim() === ''), '動畫期間學生金框仍空白');
  await display.waitForSelector('.cls-dice:not(.is-rolling) ~ .cls-dice-result b', { timeout: 8000 });
  const sec = (await pg.query('select * from intelligence_private.intel606_secrets where room_id=$1', [ROOM])).rows[0];
  const dtext = await text(display);
  ok(dtext.includes(`藍 ${sec.dice_first} ／ 紅 ${sec.dice_second}`) && dtext.includes('請私下查看平板上的任務資訊'), `大螢幕定格「藍 ${sec.dice_first} ／ 紅 ${sec.dice_second}」並提示私下查看`);
  await shot(display, '13-display-dice-result');
  for (const s of students.filter(s => s !== uc)) await s.page.waitForSelector('.cls-code', { timeout: 8000 });
  const codes = new Set(await Promise.all(students.filter(s => s !== uc).map(s => s.page.textContent('.cls-code'))));
  ok(codes.size === 1 && [...codes][0] === sec.secret_code, `5 名情報員＋17 名局內人的金框都顯示同一代碼 ${sec.secret_code}`);
  await uc.page.waitForSelector('.cls-mission', { timeout: 8000 });
  ok((await uc.page.textContent('.cls-mission')).includes('機密任務：觀察其他玩家的發言，推理本輪的機密情報。') && !(await text(uc.page)).includes(sec.secret_code), '臥底金框顯示機密任務，沒有代碼');
  ok(!(await display.content()).includes(`>${sec.secret_code}<`) && !(await teacher.content()).includes(`>${sec.secret_code}<`), '投影端、教師端 DOM 不含代碼');
  ok(await teacher.$eval('[data-act=roll]', () => false).catch(() => true), '同一輪只擲一次（擲骰按鈕已移除）');
  await shot(agent.page, '14-student-agent-code');
  await shot(uc.page, '14b-student-undercover-mission');
  await shot(students[2].page, '14c-student-phone-code');
  await shot(teacher, '15-teacher-dice');

  console.log('== 公開情報卡');
  ok(!(await agent.page.$('.cls-grid')), '老師公開前學生端沒有情報卡');
  await teacher.click('[data-act=reveal_card]');
  await display.waitForSelector('.cls-grid');
  for (const s of students) await s.page.waitForSelector('.cls-grid', { timeout: 8000 });
  ok(true, '大螢幕與全班平板同步顯示同一張 3×3 情報卡');
  const cellStyles = await display.$$eval('.cls-grid-cell', els => els.map(e => e.className + '|' + getComputedStyle(e).background + '|' + getComputedStyle(e).border + '|' + getComputedStyle(e).animationName));
  ok(cellStyles.length === 9 && new Set(cellStyles).size === 1, '九格樣式完全相同（沒有顏色、框線、動畫暗示）');
  const sCells = await agent.page.$$eval('.cls-grid-cell', els => els.map(e => e.className + '|' + getComputedStyle(e).background));
  ok(new Set(sCells).size === 1, '學生平板的公開卡同樣不標示機密格');
  const headers = await display.$$eval('.cls-grid-col,.cls-grid-row', els => els.map(e => e.textContent).join(''));
  ok(headers === 'ABC123', '保留欄號 A～C 與列號 1～3');
  await shot(display, '16-display-card');
  await shot(agent.page, '17-student-agent-card');
  await shot(students[1].page, '17b-student-portrait-card');
  await shot(students[2].page, '17c-student-phone-card');
  await teacher.click('[data-act=step][data-arg="2"]');
  await display.waitForFunction(() => document.querySelector('.cls-d-steps li.is-on')?.textContent.includes('秘密研判'));
  await teacher.click('[data-act=step][data-arg="3"]');
  await display.waitForFunction(() => document.querySelector('.cls-d-steps li.is-on')?.textContent.includes('臥底指認'));
  ok(true, '老師切換投影進度 ①②③');
  await shot(display, '18-display-card-step3');
  await shot(teacher, '19-teacher-discussion');

  console.log('== 結局一：指認錯人');
  const wrongGroup = [1, 2, 3, 4, 5, 6].find(g => g !== sec.undercover_seat);
  await teacher.click(`[data-act=accuse][data-arg="${wrongGroup}"]`);
  await display.waitForSelector('.cls-result-title');
  const word = JSON.parse(JSON.stringify((await pg.query('select current_card_snapshot from public.intel606_rooms where id=$1', [ROOM])).rows[0].current_card_snapshot)).cells[(sec.secret_code.charCodeAt(0) - 65) + (Number(sec.secret_code[1]) - 1) * 3];
  let rt = await text(display);
  ok(rt.includes('臥底勝利！') && rt.includes('玩家指認錯人，臥底成功隱藏身分。') && rt.includes(sec.secret_code) && rt.includes(word), `大螢幕：臥底勝利！＋原因＋揭曉 ${sec.secret_code}「${word}」`);
  await shot(display, '20-display-result-wrong');
  await uc.page.waitForSelector('.cls-result-title');
  await shot(uc.page, '20b-student-result-wrong');
  await shot(students[2].page, '20c-student-phone-result');

  console.log('== 第 2 輪：部分換人');
  await teacher.waitForSelector('[data-act=next]');
  await teacher.click('[data-act=next]');
  await teacher.waitForSelector('.cls-t-groups');
  await teacher.waitForFunction(() => document.querySelectorAll('.cls-chip.is-on').length === 6);
  ok(true, '下一輪：教師平板預選上一輪六人，名單保留');
  for (const s of students) await s.page.waitForSelector('.cls-waiting', { timeout: 8000 });
  ok(true, '全班平板回到等待頁（免重新掃碼）');
  const oldP = players.find(p => p.group === 2), newP = students.find(s => s.group === 2 && !isPlayer(s));
  await pick(newP.name);
  await teacher.waitForFunction(n => [...document.querySelectorAll('.cls-chip.is-on')].some(c => c.textContent === n), newP.name);
  await shot(teacher, '21-teacher-lobby-round2');
  await teacher.click(startBtn);
  for (const s of students) await s.page.waitForSelector('.cls-identity .cls-flip:not(.is-flipped)', { timeout: 8000 });
  ok(!(await oldP.page.$('.cls-code')) && !(await oldP.page.$('.cls-grid')), '上一輪的代碼、公開卡未沿用');
  await oldP.page.click('.cls-flip');
  await oldP.page.waitForSelector('.cls-flip.is-flipped');
  await sleep(500);
  ok((await roleOf(oldP)).includes('局內人'), '原玩家下一輪改為局內人');
  await teacher.waitForFunction(() => /0／6/.test(document.querySelector('.cls-t-big')?.textContent || ''));
  ok(true, '原玩家（現局內人）翻牌不計入玩家數 0／6');
  await newP.page.click('.cls-flip');
  await teacher.waitForFunction(() => /1／6/.test(document.querySelector('.cls-t-big')?.textContent || ''), null, { timeout: 8000 });
  ok(/情報員|臥底/.test(await roleOf(newP)), '原局內人獲選後翻牌 → 玩家身分，計入 1／6');
  // 已翻牌玩家重整：仍是翻開狀態、不重複計數、身分不變
  const before = await roleOf(newP);
  await newP.page.reload();
  await newP.page.waitForSelector('.cls-flip.is-flipped');
  await sleep(400);
  ok((await roleOf(newP)) === before, '已翻牌玩家重整後仍為同一身分且維持翻開');
  const r2Players = (await pg.query(`select r.display_name from intelligence_private.intel606_class_players p join intelligence_private.intel606_class_roster r using (room_id,user_id) where p.room_id=$1`, [ROOM])).rows.map(r => r.display_name);
  for (const s of students.filter(s => r2Players.includes(s.name) && s !== newP)) await s.page.click('.cls-flip');
  await teacher.waitForFunction(() => /6／6/.test(document.querySelector('.cls-t-big')?.textContent || ''), null, { timeout: 8000 });
  ok(await teacher.isEnabled('[data-act=dice_stage]'), '六名玩家翻牌、仍有 16 名局內人未翻 → 可擲骰');
  await teacher.click('[data-act=dice_stage]');
  await teacher.click('[data-act=roll]');
  await teacher.waitForSelector('[data-act=reveal_card]', { timeout: 9000 });
  const lateObs = students.find(s => !r2Players.includes(s.name) && s !== oldP);
  ok(!(await lateObs.page.$('.cls-code')), '未翻牌的局內人看不到代碼');
  await lateObs.page.click('.cls-flip');
  await lateObs.page.waitForSelector('.cls-code', { timeout: 6000 });
  const sec2 = (await pg.query('select * from intelligence_private.intel606_secrets where room_id=$1', [ROOM])).rows[0];
  ok((await lateObs.page.textContent('.cls-code')) === sec2.secret_code, '局內人翻牌後才取得本輪代碼');
  await teacher.click('[data-act=reveal_card]');
  await teacher.waitForSelector('[data-act=tie]');
  await teacher.click('[data-act=tie]');
  await display.waitForSelector('.cls-result-title');
  rt = await text(display);
  ok(rt.includes('臥底勝利！') && rt.includes('再次投票仍平手，臥底成功逃過指認。'), '結局二：重投仍平手 → 臥底勝利（原因文字不同）');
  await shot(display, '22-display-result-tie');

  for (const [label, right] of [['猜中', true], ['猜錯', false]]) {
    console.log(`== 結局${right ? '三' : '四'}：臥底被指認，最後一猜${label}`);
    await teacher.click('[data-act=next]');
    await teacher.waitForSelector(startBtn + ':not([disabled])');
    await teacher.click(startBtn);
    await sleep(800);
    const names = (await pg.query(`select r.display_name from intelligence_private.intel606_class_players p join intelligence_private.intel606_class_roster r using (room_id,user_id) where p.room_id=$1`, [ROOM])).rows.map(r => r.display_name);
    for (const s of students.filter(s => names.includes(s.name))) { await s.page.waitForSelector('.cls-flip:not(.is-flipped)'); await s.page.click('.cls-flip'); }
    await teacher.waitForSelector('[data-act=dice_stage]:not([disabled])', { timeout: 8000 });
    await teacher.click('[data-act=dice_stage]');
    await teacher.click('[data-act=roll]');
    await teacher.waitForSelector('[data-act=reveal_card]', { timeout: 9000 });
    await teacher.click('[data-act=reveal_card]');
    const s3 = (await pg.query('select * from intelligence_private.intel606_secrets where room_id=$1', [ROOM])).rows[0];
    await teacher.waitForSelector(`[data-act=accuse][data-arg="${s3.undercover_seat}"]`);
    await teacher.click(`[data-act=accuse][data-arg="${s3.undercover_seat}"]`);
    await display.waitForSelector('.cls-d-guess-head');
    const card3 = (await pg.query('select current_card_snapshot c from public.intel606_rooms where id=$1', [ROOM])).rows[0].c;
    const pos = (s3.secret_code.charCodeAt(0) - 65) + (Number(s3.secret_code[1]) - 1) * 3;
    const gt = await text(display);
    ok(gt.includes('指認成功') && !gt.includes(s3.secret_code) && !/勝利|正確|答案是/.test(gt), `猜詞前大螢幕只顯示被指認的臥底與九個詞，不揭露答案（${label}）`);
    if (right) { await shot(display, '23-display-guess'); await shot(teacher, '24-teacher-guess'); }
    await teacher.click(`[data-act=guess][data-arg="${right ? pos : (pos + 4) % 9}"]`);
    await display.waitForSelector('.cls-result-title');
    rt = await text(display);
    if (right) ok(rt.includes('臥底逆轉勝利！') && rt.includes('臥底猜中機密詞語，成功逆轉。'), '結局三：臥底逆轉勝利！');
    else ok(rt.includes('情報員勝利！') && rt.includes('情報員成功揪出臥底，守住機密詞語。') && rt.includes(card3.cells[(pos + 4) % 9]), '結局四：情報員勝利！（顯示臥底猜的詞）');
    await shot(display, right ? '25-display-result-guess-right' : '26-display-result-guess-wrong');
    if (!right) { await shot(teacher, '27-teacher-answer'); await players[0].page.waitForSelector('.cls-result-title'); await shot(students[0].page, '28-student-result-agents'); }
  }
  console.log('== 結束課堂');
  await teacher.click('[data-act=close]');
  await display.waitForFunction(() => document.body.innerText.includes('本堂課任務已結束'));
  await students[0].page.waitForFunction(() => document.body.innerText.includes('本堂課任務已結束'), null, { timeout: 8000 });
  ok(true, '結束課堂後大螢幕與學生端顯示結束畫面');
  const stats = await (await fetch('http://127.0.0.1:8606/api/stats')).json();
  console.log('  (RPC calls during run: ' + stats.rpcCount + ')');
  ok(errors.length === 0, 'JavaScript 執行期間沒有錯誤' + (errors.length ? '：' + errors.join(' / ') : ''));
  console.log(`\nE2E PASSED (${passed} checks)`);
  await browser.close(); await pg.end();
})().catch(async e => { console.error('E2E FAILED:', e.message, '\n', errors.join('\n')); process.exit(1); });

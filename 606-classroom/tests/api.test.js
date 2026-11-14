'use strict';
// HTTP + SSE 整合測試：23 人報到 → 一輪 → 部分換人再一輪，確認三端同步與權限。
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createApp } = require('../server/app');
const { REVEAL_DELAY_MS } = require('../server/game');

function startServer(opts = {}) {
  const { server } = createApp({ dataDir: null, ...opts });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, base: `http://127.0.0.1:${server.address().port}` })));
}
async function post(base, path, body) {
  const res = await fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json();
  if (!res.ok) throw Object.assign(new Error(data.error), { status: res.status });
  return data;
}

/** 極簡 SSE 用戶端：記錄每次收到的 state，可等待條件成立。 */
function sse(url) {
  const states = [];
  const raw = [];
  const waiters = [];
  const req = http.get(url, (res) => {
    res.setEncoding('utf8');
    let buf = '';
    res.on('data', (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0, i);
        buf = buf.slice(i + 2);
        raw.push(block);
        const ev = /^event: (.*)$/m.exec(block);
        const data = /^data: (.*)$/m.exec(block);
        if (ev && ev[1] === 'state' && data) {
          states.push(JSON.parse(data[1]));
          for (const w of waiters.slice()) w();
        }
      }
    });
  });
  const client = {
    states,
    raw,
    last: () => states[states.length - 1],
    until(pred, ms = 6000) {
      return new Promise((resolve, reject) => {
        const check = () => {
          const hit = states.find(pred);
          if (hit) {
            waiters.splice(waiters.indexOf(check), 1);
            clearTimeout(t);
            resolve(hit);
          }
        };
        const t = setTimeout(() => { waiters.splice(waiters.indexOf(check), 1); reject(new Error('timeout waiting for state')); }, ms);
        waiters.push(check);
        check();
      });
    },
    close: () => req.destroy(),
  };
  return client;
}

test('full classroom flow over HTTP/SSE with 23 students and partial swap', async (t) => {
  const { server, base } = await startServer();
  t.after(() => server.close());

  const { code, teacherKey } = await post(base, '/api/rooms', {});
  const display = sse(`${base}/api/rooms/${code}/events?as=display`);
  const teacher = sse(`${base}/api/rooms/${code}/events?as=teacher&key=${teacherKey}`);
  t.after(() => { display.close(); teacher.close(); });
  await display.until((s) => s.phase === 'lobby' && s.count === 0);

  // 23 人報到（1～5 組各 4 人，6 組 3 人）
  const students = [];
  let n = 0;
  for (let g = 1; g <= 6; g++) for (let i = 0; i < (g === 6 ? 3 : 4); i++) {
    const r = await post(base, `/api/rooms/${code}/join`, { name: `學生${++n}`, group: g });
    students.push({ ...r });
  }
  // 重整（帶 token 重新報到）不重複計入
  await post(base, `/api/rooms/${code}/join`, { token: students[0].token });
  await display.until((s) => s.count === 23);
  assert.equal(display.last().count, 23);

  const streams = students.map((s) => sse(`${base}/api/rooms/${code}/events?as=student&token=${s.token}`));
  t.after(() => streams.forEach((c) => c.close()));
  await Promise.all(streams.map((c) => c.until((s) => s.phase === 'lobby')));
  await teacher.until((s) => s.students.filter((x) => x.online).length === 23);

  const T = (action, payload = {}) => post(base, `/api/rooms/${code}/teacher`, { key: teacherKey, action, ...payload });
  await assert.rejects(T('start'), /尚未選定玩家/);
  await assert.rejects(post(base, `/api/rooms/${code}/teacher`, { key: 'nope', action: 'start' }), /教師金鑰錯誤/);

  async function playRound(rn, selectIdx) {
    const rawMark = new Map([display, teacher, ...streams].map((c) => [c, c.raw.length]));
    for (let g = 1; g <= 6; g++) await T('select', { group: g, studentId: students[selectIdx[g - 1]].studentId });
    await T('start');
    await display.until((s) => s.roundNo === rn && s.phase === 'identity');
    const views = await Promise.all(streams.map((c) => c.until((s) => s.roundNo === rn && s.phase === 'identity' && s.card)));
    assert.ok(views.every((v) => v.card.flipped === false && v.card.role === null), 'all tablets show card back');
    const playerIdx = selectIdx;
    const insiderIdx = students.map((_, i) => i).filter((i) => !playerIdx.includes(i));
    assert.equal(insiderIdx.length, 17);

    // 五名玩家 + 全部局內人翻牌 → 仍不可擲骰
    const roles = {};
    for (const i of [...playerIdx.slice(0, 5), ...insiderIdx]) {
      const v = await post(base, `/api/rooms/${code}/flip`, { token: students[i].token });
      roles[i] = v.card.role;
    }
    const tv = await teacher.until((s) => s.roundNo === rn && s.progress && s.progress.insidersFlipped === 17 && s.progress.playersFlipped === 5);
    assert.equal(tv.progress.playersFlipped, 5);
    await assert.rejects(T('roll'), /尚未翻牌/);
    const v6 = await post(base, `/api/rooms/${code}/flip`, { token: students[playerIdx[5]].token });
    roles[playerIdx[5]] = v6.card.role;
    for (const i of insiderIdx) assert.equal(roles[i], 'insider');
    assert.equal(playerIdx.filter((i) => roles[i] === 'spy').length, 1);
    assert.equal(playerIdx.filter((i) => roles[i] === 'agent').length, 5);

    await T('roll');
    const rolling = await display.until((s) => s.roundNo === rn && s.phase === 'dice');
    assert.equal(rolling.dice.revealed, false);
    assert.ok(rolling.dice.blue >= 1 && rolling.dice.blue <= 6 && rolling.dice.red >= 1 && rolling.dice.red <= 3);
    await assert.rejects(T('publish'), /動畫尚未結束/);

    // 伺服器在動畫結束時主動推播代碼
    const spyIdx = playerIdx.find((i) => roles[i] === 'spy');
    const agentIdx = playerIdx.find((i) => roles[i] === 'agent');
    const agentView = await streams[agentIdx].until((s) => s.roundNo === rn && s.card && s.card.intel, REVEAL_DELAY_MS + 3000);
    assert.ok(agentView.serverNow >= rolling.dice.revealAt, 'code not released before animation ends');
    assert.ok(streams[agentIdx].states.some((s) => s.phase === 'dice' && !s.card.intel), 'tablet saw the rolling phase without a code first');
    const code1 = agentView.card.intel.code;
    assert.match(code1, /^[ABC][123]$/);
    for (const i of playerIdx.filter((x) => roles[x] === 'agent')) assert.equal((await streams[i].until((s) => s.roundNo === rn && s.card && s.card.intel)).card.intel.code, code1);
    for (const i of insiderIdx) assert.equal((await streams[i].until((s) => s.roundNo === rn && s.card && s.card.intel)).card.intel.code, code1);
    const spyView = await streams[spyIdx].until((s) => s.roundNo === rn && s.card && s.card.intel);
    assert.equal(spyView.card.intel.code, undefined);
    assert.match(spyView.card.intel.mission, /機密任務/);

    // 臥底與投影端的所有串流資料中都不得出現本輪代碼
    const leak = (c) => c.raw.slice(rawMark.get(c)).some((b) => b.includes(`"${code1}"`));
    assert.ok(!leak(streams[spyIdx]), 'spy stream leaked code');
    assert.ok(!leak(display), 'display stream leaked code');

    await display.until((s) => s.roundNo === rn && s.dice && s.dice.revealed);
    await T('publish');
    const boards = await Promise.all([display, teacher, ...streams].map((c) => c.until((s) => s.roundNo === rn && s.phase === 'card' && s.board)));
    for (const b of boards) assert.deepEqual(b.board, boards[0].board);
    assert.equal(boards[0].board.words.length, 9);
    assert.ok(!leak(streams[spyIdx]) && !leak(display));
    return { roles, spyIdx, code1, playerIdx };
  }

  // ── 第 1 輪：各組第一位學生 ──
  const firstIdx = [0, 4, 8, 12, 16, 20];
  const r1 = await playRound(1, firstIdx);
  const spyGroup1 = students[r1.spyIdx].group;
  await T('accuse', { group: spyGroup1 }); // 正確指認 → 最後一猜
  await display.until((s) => s.phase === 'guess' && s.accusedGroup === spyGroup1);
  assert.equal(display.last().ending, null);
  await T('guess', { code: r1.code1 });
  const end1 = await display.until((s) => s.phase === 'ending');
  assert.equal(end1.ending.title, '臥底逆轉勝利！');
  assert.equal(end1.ending.secretCode, r1.code1);
  const se = await streams[5].until((s) => s.phase === 'ending');
  assert.equal(se.ending.reason, '臥底猜中機密詞語，成功逆轉。');

  // ── 下一輪：保留名單、預選上一輪六人；換掉第 1、2、3 組 ──
  await T('next');
  const lobby2 = await teacher.until((s) => s.phase === 'lobby' && s.roundNo === 2);
  assert.equal(lobby2.count, 23);
  for (let g = 1; g <= 6; g++) assert.equal(lobby2.selection[g], students[firstIdx[g - 1]].studentId);
  await display.until((s) => s.phase === 'lobby' && s.roundNo === 2 && s.count === 23);
  const secondIdx = [1, 5, 9, 12, 16, 20];
  const r2 = await playRound(2, secondIdx);
  for (const i of [0, 4, 8]) assert.equal(r2.roles[i], 'insider', 'previous players become insiders');
  for (const i of [1, 5, 9]) assert.notEqual(r2.roles[i], 'insider', 'former insiders become players');
  const wrongGroup = (students[r2.spyIdx].group % 6) + 1;
  await T('accuse', { group: wrongGroup });
  const end2 = await display.until((s) => s.phase === 'ending' && s.roundNo === 2);
  assert.equal(end2.ending.title, '臥底勝利！');
  assert.equal(end2.ending.reason, '玩家指認錯人，臥底成功隱藏身分。');
});

test('QR, short links, static pages, teacher passcode', async (t) => {
  const { server, base } = await startServer({ teacherPasscode: 'secret606' });
  t.after(() => server.close());
  await assert.rejects(post(base, '/api/rooms', {}), /通行碼錯誤/);
  const { code } = await post(base, '/api/rooms', { passcode: 'secret606' });
  const qr = await fetch(`${base}/api/rooms/${code}/qr.svg`);
  assert.equal(qr.status, 200);
  assert.match(await qr.text(), /<svg/);
  for (const [p, page] of [['j', 'join.html'], ['s', 'screen.html'], ['t', 'teacher.html']]) {
    const r = await fetch(`${base}/${p}/${code}`, { redirect: 'manual' });
    assert.equal(r.status, 302);
    assert.equal(r.headers.get('location'), `/${page}?room=${code}`);
  }
  for (const page of ['/', '/join.html', '/screen.html', '/teacher.html', '/js/common.js', '/css/app.css', '/img/card-back.webp']) {
    const r = await fetch(base + page);
    assert.equal(r.status, 200, page);
  }
  assert.equal((await fetch(`${base}/../server/game.js`)).status, 404);
  assert.equal((await fetch(`${base}/api/rooms/NOPE99`)).status, 404);
  const bad = await fetch(`${base}/api/rooms/${code}/state?as=student&token=bad`);
  assert.equal(bad.status, 401);
});

test('state survives a server restart (DATA_DIR persistence)', async (t) => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'intel606-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const a = await startServer({ dataDir: dir });
  const { code } = await post(a.base, '/api/rooms', {});
  const s = await post(a.base, `/api/rooms/${code}/join`, { name: '小明', group: 3 });
  await new Promise((r) => a.server.close(r));
  const b = await startServer({ dataDir: dir });
  t.after(() => b.server.close());
  const v = await (await fetch(`${b.base}/api/rooms/${code}/state?as=student&token=${s.token}`)).json();
  assert.equal(v.me.name, '小明');
  assert.equal(v.count, 1);
});

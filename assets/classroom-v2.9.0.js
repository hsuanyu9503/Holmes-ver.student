/* 606 情報局｜近距課堂模式 v2.9.0
 * 一場課堂、三種畫面：教師控制平板、教室大螢幕、學生平板。
 * 所有身分、骰點、代碼與勝負判定都由 Supabase RPC 產生；本檔只負責呈現。
 * 角色權限由 intel606_class_state 在伺服器端過濾：臥底、投影端與教師端在結局前都拿不到代碼與正確詞語。
 */
(() => {
  'use strict';
  // ---------- 網址參數（必須在主程式清除 #hash 之前讀取投影代碼） ----------
  const search = new URLSearchParams(location.search);
  const hashParams = new URLSearchParams(location.hash.replace(/^#/, ''));
  const urlKind = search.has('screen') ? 'display' : search.has('class') ? 'student' : null;
  const urlCode = (search.get('screen') || search.get('class') || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
  const STUDENT_KEY = 'intel606_class_student_v1';
  const DISPLAY_KEY = 'intel606_class_display_v1';
  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* 私密瀏覽可能禁止儲存 */ } },
    del(k) { try { localStorage.removeItem(k); } catch { /* ignore */ } }
  };
  if (urlKind === 'display' && hashParams.get('dt')) store.set(DISPLAY_KEY, { code: urlCode, token: hashParams.get('dt') });
  if (hashParams.has('dt')) {
    hashParams.delete('dt');
    const rest = hashParams.toString();
    history.replaceState(history.state, '', location.pathname + location.search + (rest ? '#' + rest : ''));
  }

  // ---------- 文字與素材 ----------
  const ASSET = 'assets/classroom/';
  const ROLE = {
    agent: { label: '情報員', img: ['role-agent-m.webp', 'role-agent-f.webp'] },
    undercover: { label: '臥底', img: ['role-undercover-m.webp', 'role-undercover-f.webp'] },
    observer: { label: '局內人（觀察員）', img: ['role-observer.webp', 'role-observer.webp'] }
  };
  const RESULT = {
    wrong: { title: '臥底勝利！', reason: '玩家指認錯人，臥底成功隱藏身分。', art: 'undercover' },
    tie: { title: '臥底勝利！', reason: '再次投票仍平手，臥底成功逃過指認。', art: 'undercover' },
    guess_right: { title: '臥底逆轉勝利！', reason: '臥底猜中機密詞語，成功逆轉。', art: 'undercover' },
    guess_wrong: { title: '情報員勝利！', reason: '情報員成功揪出臥底，守住機密詞語。', art: 'agents' }
  };
  const STEPS = [
    ['情報交換', '輪流分享情報，觀察他人的發言，尋找可疑線索！'],
    ['秘密研判', '回想每位玩家的發言，在心裡判斷誰最可疑。'],
    ['臥底指認', '依老師點名，六名玩家輪流口頭指認一組。']
  ];
  const MISSION = '機密任務：觀察其他玩家的發言，推理本輪的機密情報。';
  const TRANSITION_MS = 4200;
  const COLS = ['A', 'B', 'C'];

  const esc = t => String(t ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const pad2 = n => String(n ?? '').padStart(2, '0');
  const groupLabel = g => `第 ${pad2(g)} 組`;
  const who = p => p ? `${groupLabel(p.group)}　${esc(p.name || '（已離開）')}` : '—';
  const cellCode = i => COLS[i % 3] + (Math.floor(i / 3) + 1);
  const reduceMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- 模組狀態 ----------
  let core = null, kind = null, db = null, me = null;
  let state = null, sig = '', roomId = null, root = null, toastEl = null;
  let channel = null, pollTimer = null, fetching = false, pending = false, busy = false;
  let clockOffset = 0, ticker = null, timers = [], flipping = false;
  let editingLogin = false, editRoster = false, lastCount = null, loginError = '', pickedGroup = 0;
  const serverNow = () => Date.now() + clockOffset;

  // ---------- 共用基礎 ----------
  function mount() {
    if (!root) {
      root = document.createElement('div');
      root.id = 'classroomRoot';
      root.className = 'cls-root';
      document.body.appendChild(root);
      toastEl = document.createElement('div');
      toastEl.className = 'cls-toast';
      toastEl.setAttribute('role', 'alert');
      toastEl.hidden = true;
      document.body.appendChild(toastEl);
      root.addEventListener('click', onClick);
      root.addEventListener('submit', onSubmit);
      root.addEventListener('input', onInput);
    }
    return root;
  }
  function enter(which) {
    kind = which;
    document.body.classList.remove('cls-student', 'cls-display', 'cls-teacher');
    document.body.classList.add('cls-mode', 'cls-' + which);
    mount().hidden = false;
    root.dataset.screen = '';
  }
  function toast(message, info = false) {
    if (!toastEl) return;
    toastEl.textContent = message;
    toastEl.classList.toggle('info', info);
    toastEl.hidden = !message;
    clearTimeout(toastEl._t);
    if (message) toastEl._t = setTimeout(() => { toastEl.hidden = true; }, info ? 2600 : 6000);
  }
  function friendly(message) {
    if (/Could not find the function.*intel606_(class|create_classroom)/i.test(message))
      return '資料庫尚未執行 v2.9.0 課堂模式升級 SQL，請通知老師。';
    if (/Failed to fetch|NetworkError|Load failed/i.test(message)) return '網路連線不穩，請稍候再試。';
    return message;
  }
  async function rpc(name, args = {}) {
    const { data, error } = await db.rpc(name, args);
    if (error) throw new Error(friendly(error.message || '伺服器操作失敗'));
    return data;
  }
  async function act(fn) {
    if (busy) return;
    busy = true; root?.setAttribute('aria-busy', 'true');
    try { toast(''); await fn(); }
    catch (e) { toast(friendly(e.message || String(e))); }
    finally { busy = false; root?.removeAttribute('aria-busy'); }
  }
  function later(ms, fn) { timers.push(setTimeout(fn, Math.max(0, ms))); }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function stopListening() {
    if (channel && db) { db.removeChannel(channel); channel = null; }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    clearTimers(); stopTicker();
  }
  function listen() {
    stopListening();
    channel = db.channel('intel606-class-' + roomId)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'intel606_rooms', filter: 'id=eq.' + roomId }, () => refresh())
      .subscribe();
    // Realtime 中斷時仍可同步；教師與投影端較常輪詢，以掌握局內人翻牌進度。
    pollTimer = setInterval(() => { if (!document.hidden) refresh(); }, kind === 'student' ? 5000 : 3000);
  }
  async function refresh() {
    if (!roomId || !db) return;
    if (fetching) { pending = true; return; }
    fetching = true;
    try { apply(await rpc('intel606_class_state', { p_room: roomId })); }
    catch (e) {
      if (/無權讀取此房間|找不到課堂房間/.test(e.message)) lost();
    }
    finally {
      fetching = false;
      if (pending) { pending = false; refresh(); }
    }
  }
  function apply(next) {
    if (!next || !next.room_id) return;
    const t = Date.parse(next.server_now);
    if (Number.isFinite(t)) clockOffset = t - Date.now();
    const prev = state;
    const changedRoom = roomId !== next.room_id;
    state = next; roomId = next.room_id;
    if (changedRoom) listen();
    // 學生畫面不受其他人報到／翻牌的計數影響，避免輸入或動畫被重繪打斷。
    const base = { ...next, server_now: null };
    if (kind === 'student') Object.assign(base, { version: null, student_count: null, player_count: null, players_flipped: null, observer_count: null, observers_flipped: null });
    const nextSig = JSON.stringify(base);
    if (nextSig !== sig) { sig = nextSig; render(prev); }
    schedule();
  }
  function lost() {
    const was = kind;
    stopListening(); state = null; sig = ''; roomId = null;
    if (was === 'student') {
      const saved = store.get(STUDENT_KEY);
      if (saved) store.set(STUDENT_KEY, { ...saved, room_id: null });
      loginError = '老師已更新報到名單，請重新報到。';
      render();
    } else if (was === 'display') {
      renderMessage('投影連結已失效', '請從教師控制平板重新開啟投影畫面。');
    } else {
      leaveTeacher();
    }
  }
  function rollEndsAt() {
    if (!state?.dice_rolled || state.dice_ready || !state.roll_started_at) return 0;
    return Date.parse(state.roll_started_at) + 3000;
  }
  function schedule() {
    clearTimers();
    const end = rollEndsAt();
    if (end) {
      startTicker();
      // 伺服器 3 秒後才釋出點數；到點立即補讀，並保留一次重試。
      later(end - serverNow() + 150, refresh);
      later(end - serverNow() + 1600, refresh);
    } else stopTicker();
    if (kind === 'display' && state?.phase === 'identity' && state.identity_started_at) {
      const done = Date.parse(state.identity_started_at) + TRANSITION_MS;
      if (done > serverNow()) later(done - serverNow() + 60, () => { sig = ''; render(); });
    }
  }
  function startTicker() {
    if (ticker) return;
    const tick = () => {
      document.querySelectorAll('.cls-die[data-die="blue"] .cls-die-num').forEach(el => { el.textContent = 1 + Math.floor(Math.random() * 6); });
      document.querySelectorAll('.cls-die[data-die="red"] .cls-die-num').forEach(el => { el.textContent = 1 + Math.floor(Math.random() * 3); });
    };
    tick();
    ticker = setInterval(() => { if (!document.hidden) tick(); }, reduceMotion() ? 400 : 90);
  }
  function stopTicker() { if (ticker) { clearInterval(ticker); ticker = null; } }
  function keepScroll(fn) {
    const saved = {};
    root.querySelectorAll('[data-scroll-key]').forEach(el => { saved[el.dataset.scrollKey] = el.scrollTop; });
    fn();
    root.querySelectorAll('[data-scroll-key]').forEach(el => { if (saved[el.dataset.scrollKey]) el.scrollTop = saved[el.dataset.scrollKey]; });
  }
  function paint(screenKey, html) {
    keepScroll(() => { root.dataset.screen = screenKey; root.innerHTML = html; });
  }
  function render(prev) {
    if (!root) return;
    if (kind === 'student') renderStudent(prev);
    else if (kind === 'display') renderDisplay(prev);
    else if (kind === 'teacher') renderTeacher(prev);
  }
  function renderMessage(title, text) {
    paint('message', `<main class="cls-screen cls-message"><div class="cls-plaque">606 情報局</div><h1 class="cls-msg-title">${esc(title)}</h1><p class="cls-msg-text">${esc(text)}</p></main>`);
  }
  function roleImage(role) {
    // 情報員／臥底有男女兩款，依帳號與輪次固定挑選，重新整理也不會換圖；不影響任何遊戲資訊。
    const seed = String(me?.id || '') + ':' + (state?.round || 1);
    let h = 0; for (const ch of seed) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
    return ASSET + ROLE[role].img[h % 2];
  }
  function preloadRoles() {
    if (preloadRoles.done) return; preloadRoles.done = true;
    for (const r of Object.values(ROLE)) for (const f of r.img) { const i = new Image(); i.src = ASSET + f; }
  }
  function cardGrid(card, { compact = false } = {}) {
    if (!card || !Array.isArray(card.cells)) return '';
    // 九格完全同樣式：公開卡不以任何顏色、框線、動畫或選取狀態暗示機密格位。
    let cells = '<div class="cls-grid-corner" aria-hidden="true"></div>' + COLS.map(c => `<div class="cls-grid-col">${c}</div>`).join('');
    for (let r = 0; r < 3; r++) {
      cells += `<div class="cls-grid-row">${r + 1}</div>`;
      for (let c = 0; c < 3; c++) {
        const i = r * 3 + c;
        cells += `<div class="cls-grid-cell" aria-label="${cellCode(i)} ${esc(card.cells[i])}">${esc(card.cells[i])}</div>`;
      }
    }
    return `<div class="cls-intel ${compact ? 'is-compact' : ''}"><div class="cls-intel-title">${esc(card.title)}</div><div class="cls-grid" role="table" aria-label="公開情報卡 ${esc(card.title)}">${cells}</div></div>`;
  }
  function resultDetail(res, { large = false } = {}) {
    if (!res) return '';
    const rows = [];
    if (res.type === 'wrong' && res.accused) rows.push(['最高票玩家', `${who(res.accused)}（不是臥底）`]);
    rows.push(['本輪臥底', who(res.undercover)]);
    rows.push(['機密代碼', `<b class="cls-res-code">${esc(res.code || '—')}</b>　${esc(res.word || '')}`]);
    if (res.guess_word) rows.push(['臥底猜測', `${esc(res.guess_word)}（${res.type === 'guess_right' ? '猜中' : '猜錯'}）`]);
    return `<dl class="cls-res-detail ${large ? 'is-large' : ''}">${rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('')}</dl>`;
  }
  function resultBlock(res, { large = false, extra = '' } = {}) {
    const info = RESULT[res?.type];
    if (!info) return '<p class="cls-msg-text">正在讀取結局⋯</p>';
    return `<section class="cls-result art-${info.art} ${large ? 'is-large' : ''}">
      <div class="cls-result-art" aria-hidden="true"><img src="${ASSET}result-${info.art}.webp" alt=""></div>
      <div class="cls-result-text">
        <div class="cls-plaque">606 情報局</div>
        <h1 class="cls-result-title">${info.title}</h1>
        <p class="cls-result-reason">${info.reason}</p>
        ${resultDetail(res, { large })}
        ${extra}
      </div></section>`;
  }

  // ======================================================================
  // 學生平板
  // ======================================================================
  function renderStudent() {
    if (editingLogin && state?.phase !== 'lobby') editingLogin = false;
    if (!state || editingLogin) {
      if (editingLogin && root.dataset.screen === 'login') return; // 正在修改報到資料時不重繪
      return renderLogin();
    }
    const ph = state.phase;
    if (ph === 'closed') return renderMessage('本堂課任務已結束', '謝謝你的參與！');
    if (ph === 'lobby') return renderWaiting();
    if (ph === 'answer') return renderStudentResult();
    return renderIdentity();
  }
  function renderLogin() {
    const saved = store.get(STUDENT_KEY);
    const typed = root.querySelector('#clsName')?.value;
    const name = typed ?? state?.me?.name ?? (saved?.code === urlCode ? saved?.name : '') ?? '';
    const group = Number(pickedGroup || state?.me?.group || (saved?.code === urlCode ? saved?.group : 0) || 0);
    const groups = [1, 2, 3, 4, 5, 6].map(g =>
      `<button type="button" class="cls-group ${g === group ? 'is-on' : ''}" role="radio" aria-checked="${g === group}" data-pick-group="${g}">${pad2(g)}</button>`).join('');
    paint('login', `<main class="cls-screen cls-login">
      <header class="cls-login-head"><img src="assets/crest-display.webp" alt="" class="cls-crest"><h1>606 情報局</h1><div class="cls-ribbon">連線任務</div></header>
      <form class="cls-login-form" id="clsLoginForm" novalidate>
        <label class="cls-field-label" for="clsName"><span aria-hidden="true">👤</span> 情報員姓名</label>
        <input id="clsName" maxlength="24" autocomplete="off" placeholder="請輸入你的姓名" value="${esc(name)}" required>
        <div class="cls-field-label" id="clsGroupLabel"><span aria-hidden="true">👥</span> 選擇所屬組別</div>
        <div class="cls-groups" role="radiogroup" aria-labelledby="clsGroupLabel">${groups}</div>
        <button type="submit" class="cls-join"><span aria-hidden="true">📟</span> 加入情報任務</button>
        <p class="cls-login-error" role="alert" ${loginError ? '' : 'hidden'}>${esc(loginError)}</p>
      </form></main>`);
    pickedGroup = group || 0;
  }
  async function submitLogin() {
    const name = String(root.querySelector('#clsName')?.value || '').trim();
    const group = Number(pickedGroup || 0);
    if (!name) { loginError = '請輸入你的姓名。'; return renderLogin(); }
    if (!(group >= 1 && group <= 6)) { loginError = '請點選你的組別。'; return renderLogin(); }
    loginError = '';
    await act(async () => {
      const s = await rpc('intel606_class_join', { p_code: urlCode, p_name: name, p_group: group });
      store.set(STUDENT_KEY, { room_id: s.room_id, code: urlCode, name, group });
      editingLogin = false; sig = '';
      apply(s);
    });
    if (toastEl && !toastEl.hidden && (!state || editingLogin)) { loginError = toastEl.textContent; toast(''); root.dataset.screen = ''; renderLogin(); }
  }
  function studentHeader(title) {
    return `<header class="cls-head"><div class="cls-head-title">606 情報局｜${title}</div>
      <div class="cls-head-sub">情報員：${esc(state.me.name)}｜${groupLabel(state.me.group)}</div></header>`;
  }
  function renderWaiting() {
    paint('waiting', `<main class="cls-screen cls-waiting">
      <div class="cls-wait-shield" aria-hidden="true">✓</div>
      ${studentHeader('連線任務')}
      <h1 class="cls-wait-title">正在等待任務指令⋯</h1>
      <p class="cls-wait-desc">你已完成報到，請留在此畫面，<br>等待全體情報員集合。</p>
      <div class="cls-next"><span class="cls-clock" aria-hidden="true">⏱</span><span>下一步：啟動身份認證</span></div>
      <p class="cls-next-note">任務開始後將核對你的身分情報</p>
      <div class="cls-dots" aria-hidden="true"><i></i><i></i><i></i></div>
      <button type="button" class="cls-link" data-act="edit-login">報到資料有誤？重新填寫</button>
    </main>`);
  }
  function renderIdentity() {
    const s = state, m = s.me;
    const key = 'identity:' + s.round;
    const fresh = root.dataset.screen !== key;
    if (fresh) {
      preloadRoles();
      paint(key, `<main class="cls-screen cls-identity">
        ${studentHeader('身份認證')}
        <div class="cls-id-body">
          <button type="button" class="cls-flip ${m.flipped ? 'is-flipped no-anim' : ''}" data-act="flip" aria-label="點選卡面確認你的身分">
            <span class="cls-flip-inner">
              <span class="cls-face cls-back"><img src="${ASSET}card-back.webp" alt="身分卡背面"></span>
              <span class="cls-face cls-front"><img alt=""></span>
            </span>
          </button>
          <div class="cls-id-right">
            <div class="cls-step" data-step="1"><b>1</b><span>點選卡面確認你的身分</span><i class="cls-step-ok" aria-hidden="true">✓</i></div>
            <div class="cls-step" data-step="2"><b>2</b><span>等待老師公布情報代碼</span></div>
            <div class="cls-codebox" aria-live="polite"></div>
            <div class="cls-id-public" hidden></div>
          </div>
        </div></main>`);
      if (m.flipped) requestAnimationFrame(() => requestAnimationFrame(() => root.querySelector('.cls-flip')?.classList.remove('no-anim')));
    }
    root.querySelector('.cls-head-sub').textContent = `情報員：${m.name}｜${groupLabel(m.group)}`;
    const flip = root.querySelector('.cls-flip');
    const front = flip.querySelector('.cls-front img');
    if (m.flipped && m.role) {
      const src = roleImage(m.role);
      if (front.getAttribute('src') !== src) { front.src = src; front.alt = `你的身分：${ROLE[m.role].label}`; }
      flip.classList.add('is-flipped');
      flip.setAttribute('aria-label', `你的身分：${ROLE[m.role].label}`);
    } else {
      flip.classList.remove('is-flipped');
    }
    root.querySelector('.cls-step[data-step="1"]').classList.toggle('is-done', !!m.flipped);
    // 金框：情報員／局內人在動畫結束後顯示代碼；臥底顯示機密任務；其餘時間保持空白。
    const box = root.querySelector('.cls-codebox');
    let content = '', mode = 'empty';
    if (m.code) { content = `<span class="cls-code">${esc(m.code)}</span>`; mode = 'code:' + m.code; }
    else if (m.role === 'undercover' && s.dice_ready) { content = `<span class="cls-mission">${esc(MISSION)}</span>`; mode = 'mission'; }
    if (box.dataset.mode !== mode) {
      box.dataset.mode = mode; box.innerHTML = content;
      box.classList.toggle('is-filled', mode !== 'empty');
      if (mode !== 'empty' && !fresh) { box.classList.remove('glow'); void box.offsetWidth; box.classList.add('glow'); }
    }
    const pub = ['discussion', 'guess'].includes(s.phase) && s.card;
    root.querySelector('.cls-id-right').classList.toggle('is-public', !!pub);
    const pubEl = root.querySelector('.cls-id-public');
    pubEl.hidden = !pub;
    if (pub) {
      let banner = '';
      if (s.phase === 'guess' && s.accused) {
        const mine = m.role === 'undercover';
        banner = `<div class="cls-guess-banner"><b>指認成功！</b>${who(s.accused)} 就是臥底<small>${mine ? '請從九個詞語中，口頭說出你的猜測（只有一次機會）' : '等待臥底從九個詞語中口頭猜一次'}</small></div>`;
      }
      const pubKey = s.phase + ':' + JSON.stringify(s.card.cells) + ':' + (s.accused?.group || '');
      if (pubEl.dataset.key !== pubKey) { pubEl.dataset.key = pubKey; pubEl.innerHTML = banner + cardGrid(s.card, { compact: true }); }
    }
  }
  async function doFlip() {
    if (!state || state.me.flipped || flipping) return;
    flipping = true;
    const flip = root.querySelector('.cls-flip');
    flip?.classList.add('is-pressed');
    try { apply(await rpc('intel606_class_flip', { p_room: roomId })); }
    catch (e) { toast(friendly(e.message)); }
    finally { flipping = false; root.querySelector('.cls-flip')?.classList.remove('is-pressed'); }
  }
  function renderStudentResult() {
    const m = state.me;
    const mine = m.role ? `<p class="cls-res-mine">你這一輪的身分：<b>${ROLE[m.role].label}</b></p>` : '';
    paint('s-answer:' + state.round, `<main class="cls-screen cls-s-result">
      ${resultBlock(state.result, { extra: mine + '<p class="cls-res-wait">本輪結束，請等待老師開始下一輪。</p>' })}</main>`);
  }

  // ======================================================================
  // 教室大螢幕（只呈現公開資訊）
  // ======================================================================
  function renderDisplay(prev) {
    const s = state, ph = s.phase;
    if (ph === 'closed') return renderMessage('本堂課任務已結束', '謝謝各位情報員！');
    if (ph === 'lobby') {
      const bump = lastCount !== null && lastCount !== s.student_count;
      lastCount = s.student_count;
      let qr = '';
      if (s.show_join_qr && s.code) {
        try { qr = `<aside class="cls-d-qr"><img src="${core.qr(studentLink(s.code))}" alt="學生報到 QR Code"><span>掃描報到</span></aside>`; } catch { qr = ''; }
      }
      return paint('d-lobby', `<main class="cls-screen cls-d-lobby">
        <div class="cls-d-lobby-title">606 情報局｜任務集結中</div>
        <div class="cls-d-count ${bump ? 'bump' : ''}" aria-live="polite"><span class="cls-d-num">${Number(s.student_count) || 0}</span><span class="cls-d-unit">人</span></div>
        ${qr}</main>`);
    }
    lastCount = null;
    if (ph === 'identity') {
      const started = Date.parse(s.identity_started_at || '') || 0;
      const elapsed = Math.max(0, serverNow() - started);
      const transition = elapsed < TRANSITION_MS;
      const pct = s.player_count ? Math.round(100 * s.players_flipped / s.player_count) : 0;
      return paint('d-identity', `<main class="cls-screen cls-d-frame cls-d-identity">
        <div class="cls-plaque">606 情報局</div>
        <div class="cls-d-banner">${transition ? '正在啟動身份認證⋯' : '身份認證進行中'}</div>
        ${transition
          ? `<div class="cls-d-bar is-flow"><span style="animation-delay:-${elapsed}ms"></span></div><p class="cls-d-hint">請看自己的平板</p>`
          : `<div class="cls-d-bar"><span style="width:${pct}%"></span></div>
             <p class="cls-d-progress">玩家已翻牌 <b>${s.players_flipped}</b>／${s.player_count || 6}</p>
             <p class="cls-d-hint">請點選平板上的卡面，確認你的身分</p>`}
      </main>`);
    }
    if (ph === 'dossier') return paint('d-dice', diceStage(true));
    if (ph === 'discussion') {
      const step = Math.min(3, Math.max(1, Number(s.discussion_step) || 1));
      const steps = STEPS.map(([name], i) => `<li class="${i + 1 === step ? 'is-on' : i + 1 < step ? 'is-done' : ''}"><b>${i + 1}</b>${name}</li>`).join('<li class="cls-step-sep" aria-hidden="true"></li>');
      return paint('d-card', `<main class="cls-screen cls-d-frame cls-d-card">
        <div class="cls-plaque">606 情報局</div>
        ${cardGrid(s.card)}
        <ol class="cls-d-steps">${steps}</ol>
        <p class="cls-d-callout"><span aria-hidden="true">📣</span>${STEPS[step - 1][1]}</p></main>`);
    }
    if (ph === 'guess') {
      return paint('d-guess', `<main class="cls-screen cls-d-frame cls-d-guess">
        <div class="cls-plaque">606 情報局</div>
        <div class="cls-d-guess-head"><b>指認成功！</b><span>${who(s.accused)} 就是臥底</span></div>
        <p class="cls-d-callout"><span aria-hidden="true">🎯</span>臥底最後一猜：請從九個詞語中，口頭說出一個答案</p>
        ${cardGrid(s.card)}</main>`);
    }
    if (ph === 'answer') return paint('d-answer', `<main class="cls-screen cls-d-answer">${resultBlock(s.result, { large: true })}</main>`);
    renderMessage('606 情報局', '');
  }
  function diceStage(forDisplay) {
    const s = state;
    const rolling = !!rollEndsAt() || (s.dice_rolled && !s.dice_ready);
    const ready = s.dice_ready && Number.isInteger(s.dice_first);
    const num = (v, color) => ready ? v : rolling ? (color === 'blue' ? 1 + Math.floor(Math.random() * 6) : 1 + Math.floor(Math.random() * 3)) : '？';
    const blocks = `<div class="cls-dice ${rolling ? 'is-rolling' : ''}">
        <figure class="cls-die" data-die="blue"><figcaption>藍色六面骰（1～6）</figcaption><div class="cls-die-box"><span class="cls-die-num">${num(s.dice_first, 'blue')}</span></div></figure>
        <figure class="cls-die" data-die="red"><figcaption>紅色六面骰（1～3，各兩面）</figcaption><div class="cls-die-box"><span class="cls-die-num">${num(s.dice_second, 'red')}</span></div></figure>
      </div>`;
    const line = ready
      ? `<div class="cls-dice-result"><span>本輪公開骰子點數：</span><b>藍 ${s.dice_first} ／ 紅 ${s.dice_second}</b></div>`
      : `<div class="cls-dice-result is-wait"><span>${rolling ? '骰子滾動中⋯' : '等待老師擲骰'}</span></div>`;
    if (!forDisplay) return blocks + line;
    return `<main class="cls-screen cls-d-frame cls-d-dice"><div class="cls-plaque">606 情報局</div>${blocks}${line}
      <p class="cls-d-callout ${ready ? '' : 'is-hidden'}"><span aria-hidden="true">🔐</span>請私下查看平板上的任務資訊</p></main>`;
  }

  // ======================================================================
  // 教師控制平板
  // ======================================================================
  function studentLink(code) {
    const link = new URL('online.html', document.baseURI);
    link.searchParams.set('class', code);
    link.hash = core.publicConfigHash();
    return link.href;
  }
  function displayLink() {
    const link = new URL('online.html', document.baseURI);
    link.searchParams.set('screen', state.code);
    const h = new URLSearchParams(core.publicConfigHash());
    h.set('dt', state.display_token);
    link.hash = h.toString();
    return link.href;
  }
  const PHASE_NAME = { lobby: '報到與選人', identity: '身分認證', dossier: '擲骰與私人代碼', discussion: '公開情報卡・發言與投票', guess: '臥底最後一猜', answer: '結局', closed: '已結束' };
  function tBtn(label, action, { cls = 'cls-btn', disabled = false, arg = '' } = {}) {
    return `<button type="button" class="${cls}" data-act="${action}" ${arg !== '' ? `data-arg="${esc(arg)}"` : ''} ${disabled ? 'disabled' : ''}>${label}</button>`;
  }
  function renderTeacher() {
    const s = state;
    if (!s) return;
    const ph = s.phase;
    const header = `<header class="cls-t-head">
      <div class="cls-t-brand"><img src="assets/crest-header.webp" alt=""><div><b>606 情報局｜教師控制台</b><small>房間 ${esc(s.code)}・第 ${s.round} 輪・${PHASE_NAME[ph] || ph}</small></div></div>
      <div class="cls-t-tools">
        ${ph !== 'closed' ? tBtn('🖥 投影畫面', 'show-display', { cls: 'cls-btn ghost' }) + tBtn('▦ 學生 QR', 'show-qr', { cls: 'cls-btn ghost' }) : ''}
        ${tBtn('情報卡資料庫', 'library', { cls: 'cls-btn ghost' })}
        ${tBtn('離開', 'leave', { cls: 'cls-btn ghost' })}
      </div></header>`;
    let body = '';
    if (ph === 'lobby') body = teacherLobby();
    else if (ph === 'identity') body = teacherIdentity();
    else if (ph === 'dossier') body = teacherDice();
    else if (ph === 'discussion') body = teacherDiscussion();
    else if (ph === 'guess') body = teacherGuess();
    else if (ph === 'answer') body = teacherAnswer();
    else body = `<section class="cls-t-panel"><h2>本堂課已結束</h2><p>可以按「離開」回到首頁建立新的課堂。</p></section>`;
    const footer = ph === 'closed' ? '' : `<footer class="cls-t-foot">
      ${['identity', 'dossier', 'discussion', 'guess'].includes(ph) ? tBtn('取消本輪・重新選人', 'abort', { cls: 'cls-btn ghost' }) : '<span></span>'}
      ${tBtn('結束課堂', 'close', { cls: 'cls-btn danger' })}</footer>`;
    paint('t-' + ph, `<main class="cls-teacher">${header}${body}${footer}</main>${teacherOverlay()}`);
  }
  function teacherLobby() {
    const s = state;
    const roster = Array.isArray(s.roster) ? s.roster : [];
    const picked = new Map((s.players || []).map(p => [p.group, p.id]));
    const groups = [1, 2, 3, 4, 5, 6].map(g => {
      const list = roster.filter(r => r.group === g);
      const chips = list.length ? list.map(r => {
        const on = picked.get(g) === r.id;
        return `<span class="cls-chip-wrap"><button type="button" class="cls-chip ${on ? 'is-on' : ''}" data-act="pick" data-group="${g}" data-user="${esc(r.id)}" aria-pressed="${on}">${esc(r.name)}</button>${editRoster ? `<button type="button" class="cls-chip-x" data-act="remove" data-user="${esc(r.id)}" aria-label="移除 ${esc(r.name)}">✕</button>` : ''}</span>`;
      }).join('') : '<span class="cls-empty">尚無人報到</span>';
      return `<article class="cls-t-group ${picked.has(g) ? 'is-ready' : ''}"><h3>${groupLabel(g)}<small>${list.length} 人</small></h3><div class="cls-chips">${chips}</div></article>`;
    }).join('');
    const ready = picked.size;
    let qr = '';
    try { qr = `<img class="cls-t-qr" src="${core.qr(studentLink(s.code))}" alt="學生報到 QR Code">`; } catch { qr = '<p>QR Code 模組未載入，請使用連結。</p>'; }
    return `<div class="cls-t-lobby">
      <section class="cls-t-panel cls-t-join">
        <h2>學生掃碼報到</h2>${qr}
        <div class="cls-t-count"><b>${s.student_count}</b> 人已報到</div>
        <label class="cls-switch"><input type="checkbox" data-act="toggle-qr" ${s.show_join_qr ? 'checked' : ''}><span>在大螢幕顯示報到 QR Code</span></label>
        ${tBtn('複製學生報到連結', 'copy-student', { cls: 'cls-btn ghost small' })}
      </section>
      <section class="cls-t-panel cls-t-pick">
        <div class="cls-t-pick-head"><h2>每組點選一名玩家</h2>
          <button type="button" class="cls-btn ghost small" data-act="edit-roster">${editRoster ? '完成管理' : '管理名單'}</button></div>
        <div class="cls-t-groups" data-scroll-key="groups">${groups}</div>
        <div class="cls-t-cta"><span>已選 <b>${ready}</b>／6 組${ready === 6 ? '' : '　（六組都選好才能啟動）'}</span>
          ${tBtn('啟動身分認證', 'start', { cls: 'cls-btn primary big', disabled: ready !== 6 })}</div>
      </section></div>`;
  }
  function playersList() {
    return `<ul class="cls-t-players">${(state.players || []).map(p =>
      `<li class="${p.flipped ? 'is-done' : ''}"><span>${groupLabel(p.group)}</span><b>${esc(p.name)}</b><em>${p.flipped ? '✓ 已翻牌' : '等待翻牌'}</em></li>`).join('')}</ul>`;
  }
  function teacherIdentity() {
    const s = state;
    const all = s.players_flipped === 6;
    return `<section class="cls-t-panel cls-t-stage">
      <h2>玩家已翻牌 <b class="cls-t-big">${s.players_flipped}／6</b></h2>
      ${playersList()}
      <p class="cls-t-note">局內人已翻牌 ${s.observers_flipped}／${s.observer_count}（不影響進度）</p>
      <div class="cls-t-cta"><span>${all ? '六名玩家都已翻牌，可以進入擲骰。' : '六名玩家全部翻牌後，才能擲骰。'}</span>
        ${tBtn('進入擲骰', 'dice_stage', { cls: 'cls-btn primary big', disabled: !all })}</div></section>`;
  }
  function teacherDice() {
    const s = state;
    const rolling = s.dice_rolled && !s.dice_ready;
    let cta;
    if (!s.dice_rolled) cta = tBtn('🎲 擲骰', 'roll', { cls: 'cls-btn primary big' });
    else if (rolling) cta = tBtn('骰子滾動中⋯', 'noop', { cls: 'cls-btn primary big', disabled: true });
    else cta = tBtn('公開情報卡', 'reveal_card', { cls: 'cls-btn primary big' });
    return `<section class="cls-t-panel cls-t-stage cls-t-dice">${diceStage(false)}
      <p class="cls-t-note">${!s.dice_rolled ? '按下擲骰後，大螢幕同步播放動畫；兩顆骰子由資料庫統一產生。' : rolling ? '動畫結束後，情報員與局內人的平板會自動顯示代碼。' : '學生正在私下查看平板。確認大家看完後，再公開情報卡。'}</p>
      <div class="cls-t-cta"><span></span>${cta}</div></section>`;
  }
  function stepButtons() {
    const step = Number(state.discussion_step) || 1;
    return `<div class="cls-t-steps" role="group" aria-label="投影進度">${STEPS.map(([name], i) =>
      `<button type="button" class="cls-step-btn ${i + 1 === step ? 'is-on' : ''}" data-act="step" data-arg="${i + 1}" aria-pressed="${i + 1 === step}">${i + 1} ${name}</button>`).join('')}</div>`;
  }
  function teacherDiscussion() {
    const s = state;
    const voters = (s.players || []).map(p => `<button type="button" class="cls-vote" data-act="accuse" data-arg="${p.group}"><span>${groupLabel(p.group)}</span><b>${esc(p.name)}</b></button>`).join('');
    return `<div class="cls-t-split">
      <section class="cls-t-panel cls-t-cardview">${cardGrid(s.card, { compact: true })}
        <h3>投影進度</h3>${stepButtons()}</section>
      <section class="cls-t-panel cls-t-verdict">
        <h2>現場投票結果</h2>
        <p class="cls-t-note">六名玩家輪流發言後，依序口頭投給一組。點選<b>最高票</b>的玩家，系統會判定是否為臥底。</p>
        <div class="cls-votes">${voters}</div>
        <p class="cls-t-note">最高票平手時：並列玩家各補充一句，再由六名玩家針對並列者重投一次。</p>
        ${tBtn('重投後仍平手 → 臥底勝利', 'tie', { cls: 'cls-btn ghost wide' })}
      </section></div>`;
  }
  function teacherGuess() {
    const s = state;
    const words = (s.card?.cells || []).map((w, i) => `<button type="button" class="cls-word" data-act="guess" data-arg="${i}"><small>${cellCode(i)}</small>${esc(w)}</button>`).join('');
    return `<section class="cls-t-panel cls-t-stage">
      <h2>${who(s.accused)} 被正確指認為臥底</h2>
      <p class="cls-t-note">請臥底從九個詞語中口頭猜一次。臥底說出後，點選他說的詞語，系統會判定結果並公布答案。</p>
      <div class="cls-words">${words}</div></section>`;
  }
  function teacherAnswer() {
    return `<section class="cls-t-panel cls-t-stage cls-t-answer">${resultBlock(state.result)}
      <div class="cls-t-cta"><span>下一輪會保留全班名單，並預選這一輪的六人。</span>${tBtn('下一輪', 'next', { cls: 'cls-btn primary big' })}</div></section>`;
  }
  let overlay = '';
  function teacherOverlay() {
    if (!overlay || !state) return '';
    const link = overlay === 'display' ? displayLink() : studentLink(state.code);
    let qr = '';
    try { qr = `<img class="cls-t-qr" src="${core.qr(link)}" alt="">`; } catch { /* ignore */ }
    const title = overlay === 'display' ? '教室大螢幕' : '學生報到';
    const help = overlay === 'display'
      ? '在連接投影機的電腦或平板開啟此連結（全螢幕顯示）。投影畫面只呈現公開資訊，請勿分享給學生。'
      : '學生掃描後輸入姓名、選擇組別即可報到。遊戲進行中晚到的學生，本輪會成為局內人。';
    return `<div class="cls-overlay" role="dialog" aria-modal="true" aria-label="${title}"><div class="cls-overlay-box">
      <h2>${title}</h2>${qr}<p>${help}</p>
      <textarea readonly rows="3" class="cls-link-field">${esc(link)}</textarea>
      <div class="cls-overlay-actions">
        ${tBtn('複製連結', overlay === 'display' ? 'copy-display' : 'copy-student', { cls: 'cls-btn ghost' })}
        ${overlay === 'display' ? tBtn('在新視窗開啟', 'open-display', { cls: 'cls-btn ghost' }) : ''}
        ${tBtn('關閉', 'close-overlay', { cls: 'cls-btn primary' })}</div></div></div>`;
  }
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); toast('已複製連結。', true); }
    catch { window.prompt('請複製以下連結：', text); }
  }
  async function teacherAction(action, arg = null) {
    const s = state;
    const name = g => { const p = (s.players || []).find(x => x.group === g); return p ? `${groupLabel(g)} ${p.name}` : groupLabel(g); };
    if (action === 'accuse' && !confirm(`確認現場最高票是「${name(arg)}」？\n送出後系統會立即判定是否為臥底。`)) return;
    if (action === 'tie' && !confirm('確認重投後最高票仍然平手？\n本輪將由臥底獲勝。')) return;
    if (action === 'guess' && !confirm(`確認臥底口頭猜的是「${s.card?.cells?.[arg]}」？\n送出後立即公布答案。`)) return;
    if (action === 'abort' && !confirm('確定取消本輪？\n全班平板會回到等待畫面，可重新選人後再啟動。')) return;
    if (action === 'close' && !confirm('確定結束這堂課？\n學生與大螢幕都會看到結束畫面，房間無法再開始新一輪。')) return;
    await act(async () => { apply(await rpc('intel606_class_action', { p_room: roomId, p_action: action, p_arg: arg })); });
  }
  function leaveTeacher() {
    stopListening();
    overlay = ''; state = null; sig = ''; roomId = null; editRoster = false;
    document.body.classList.remove('cls-mode', 'cls-teacher');
    if (root) { root.hidden = true; root.innerHTML = ''; }
    core?.leaveToLanding?.();
  }

  // ---------- 事件 ----------
  function onClick(e) {
    const pick = e.target.closest('[data-pick-group]');
    if (pick) {
      pickedGroup = Number(pick.dataset.pickGroup);
      root.querySelectorAll('[data-pick-group]').forEach(b => {
        const on = b === pick; b.classList.toggle('is-on', on); b.setAttribute('aria-checked', String(on));
      });
      return;
    }
    const el = e.target.closest('[data-act]');
    if (!el || el.disabled) return;
    const a = el.dataset.act;
    const arg = el.dataset.arg !== undefined ? Number(el.dataset.arg) : null;
    if (a === 'flip') return void doFlip();
    if (a === 'edit-login') { editingLogin = true; loginError = ''; pickedGroup = state?.me?.group || 0; root.dataset.screen = ''; return renderLogin(); }
    if (kind !== 'teacher') return;
    switch (a) {
      case 'pick': {
        const g = Number(el.dataset.group), u = el.dataset.user;
        const current = (state.players || []).find(p => p.group === g);
        return void act(async () => apply(await rpc('intel606_class_select', { p_room: roomId, p_group: g, p_user: current?.id === u ? null : u })));
      }
      case 'remove': {
        const r = (state.roster || []).find(x => x.id === el.dataset.user);
        if (!r || !confirm(`確定把「${r.name}」（${groupLabel(r.group)}）移出報到名單？\n該學生需要重新報到。`)) return;
        return void act(async () => apply(await rpc('intel606_class_remove', { p_room: roomId, p_user: r.id })));
      }
      case 'edit-roster': editRoster = !editRoster; sig = ''; return renderTeacher();
      case 'toggle-qr': return void teacherAction('qr', el.checked ? 1 : 0);
      case 'show-display': overlay = 'display'; return renderTeacher();
      case 'show-qr': overlay = 'student'; return renderTeacher();
      case 'close-overlay': overlay = ''; return renderTeacher();
      case 'copy-student': return void copy(studentLink(state.code));
      case 'copy-display': return void copy(displayLink());
      case 'open-display': window.open(displayLink(), 'intel606-display'); return;
      case 'library': stopListening(); document.body.classList.remove('cls-mode', 'cls-teacher'); root.hidden = true; core.openLibrary(); return;
      case 'leave': if (confirm('離開控制台不會結束課堂，之後可從「我的房間」重新進入。確定離開？')) leaveTeacher(); return;
      case 'noop': return;
      default: return void teacherAction(a, arg);
    }
  }
  function onSubmit(e) {
    if (e.target.id === 'clsLoginForm') { e.preventDefault(); submitLogin(); }
  }
  function onInput(e) {
    if (e.target.id === 'clsName' && loginError) { loginError = ''; const p = root.querySelector('.cls-login-error'); if (p) p.hidden = true; }
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden && roomId && kind) refresh(); });
  window.addEventListener('pageshow', () => { if (roomId && kind) refresh(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && overlay) { overlay = ''; renderTeacher(); } });

  // ---------- 對外介面（由 online 主程式呼叫） ----------
  async function boot(c) {
    core = c;
    enter(urlKind);
    document.title = urlKind === 'display' ? '606 情報局｜教室大螢幕' : '606 情報局｜連線任務';
    if (!urlCode) return renderMessage('連結不完整', '請重新掃描老師提供的 QR Code。');
    if (!core.configOK) return renderMessage('尚未取得連線設定', '請重新掃描老師提供的 QR Code。');
    if (!window.supabase?.createClient) return renderMessage('無法載入連線元件', '請檢查網路連線後重新整理。');
    renderMessage('正在建立安全連線⋯', '');
    try {
      const id = await core.identity(urlKind);
      db = id.db; me = id.user;
    } catch (e) {
      return renderMessage('連線失敗', friendly(e.message) + '（請確認 Supabase 已啟用 Anonymous Sign-ins）');
    }
    if (urlKind === 'display') {
      const link = store.get(DISPLAY_KEY);
      if (!link || link.code !== urlCode || !link.token) return renderMessage('投影連結無效', '請從教師控制平板的「投影畫面」重新開啟。');
      try { apply(await rpc('intel606_class_display_join', { p_code: urlCode, p_token: link.token })); }
      catch (e) { renderMessage('投影連結無效', e.message); }
      return;
    }
    const saved = store.get(STUDENT_KEY);
    if (saved?.room_id && saved.code === urlCode) {
      try { apply(await rpc('intel606_class_state', { p_room: saved.room_id })); return; }
      catch { store.set(STUDENT_KEY, { ...saved, room_id: null }); }
    }
    render();
  }
  async function teacher(c, room) {
    core = c;
    const id = await core.identity('host');
    db = id.db; me = id.user;
    stopListening();
    const first = await rpc('intel606_class_state', { p_room: room }); // 失敗時由主程式顯示錯誤，畫面不切換
    kind = 'teacher';
    enter('teacher');
    document.title = '606 情報局｜教師控制台';
    sig = ''; roomId = null; overlay = ''; editRoster = false;
    apply(first);
  }
  function resume() {
    if (kind !== 'teacher' || !roomId) return false;
    enter('teacher'); sig = ''; listen(); refresh();
    return true;
  }
  window.INTEL606_CLASSROOM = { urlKind, boot, teacher, resume, active: () => kind === 'teacher' && !!roomId };
})();

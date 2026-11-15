import { el, qs, rpc, toast, watchRoom, configured, configMissing, roomFromUrl, pad2, crest, boardEl, endingArtEl, endingRevealEl, CARD_IMG, ROLE_NAME } from './common.js';

const app = qs('#app');
const room = roomFromUrl();
const storeKey = `intel606c:${room}`;
const storage = {
  get() { try { return localStorage.getItem(storeKey); } catch { return null; } },
  set(v) { try { localStorage.setItem(storeKey, v); } catch {} },
  clear() { try { localStorage.removeItem(storeKey); } catch {} },
};

const ICON = {
  user: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="12" cy="7.5" r="4.5"/><path d="M3 21c0-4.4 4-7.5 9-7.5s9 3.1 9 7.5z"/></svg>',
  group: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="12" cy="7" r="3.6"/><circle cx="5" cy="9" r="2.6"/><circle cx="19" cy="9" r="2.6"/><path d="M5.5 21c0-3.8 2.9-6.5 6.5-6.5s6.5 2.7 6.5 6.5z"/><path d="M0 20c0-2.9 2-5 4.8-5 1 0 1.9.3 2.6.8-1.3 1.2-2.1 2.6-2.4 4.2zM24 20c0-2.9-2-5-4.8-5-1 0-1.9.3-2.6.8 1.3 1.2 2.1 2.6 2.4 4.2z"/></svg>',
  radio: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="6" y="6" width="12" height="17" rx="2.5"/><rect x="13" y="1" width="2" height="6" rx="1"/><rect x="8.5" y="9" width="7" height="4" rx="1" fill="#d8ad5f"/><circle cx="9.5" cy="17" r="1.2" fill="#d8ad5f"/><circle cx="14.5" cy="17" r="1.2" fill="#d8ad5f"/></svg>',
  shield: '<svg class="shield" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M12 2.5 4 5.5v6c0 5 3.4 8.7 8 10 4.6-1.3 8-5 8-10v-6z"/><path d="m8.5 12 2.4 2.4 4.8-5"/></svg>',
  clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 2M9 2h6M12 2v3"/></svg>',
  spy: '<svg class="spy-icon" viewBox="0 0 120 92" aria-hidden="true"><path fill="currentColor" d="M31 40c0-19 7-31 29-31s29 12 29 31z"/><path fill="currentColor" opacity=".55" d="M31 31h58v8H31z"/><ellipse fill="currentColor" cx="60" cy="41" rx="57" ry="8.5"/><path fill="currentColor" fill-rule="evenodd" d="M17 58c15-6 30-3 43 3 13-6 28-9 43-3-1 17-11 27-24 27-9 0-15-6-19-12-4 6-10 12-19 12-13 0-23-10-24-27zm15 9c3-5 12-6 19-2-2 6-8 9-13 8-3 0-5-3-6-6zm56 0c-3-5-12-6-19-2 2 6 8 9 13 8 3 0 5-3 6-6z"/></svg>',
  laurel: '<svg class="laurel-svg" viewBox="0 0 24 48" aria-hidden="true"><path d="M18 46C8 38 6 22 14 4" fill="none" stroke="currentColor" stroke-width="1.6"/><g fill="currentColor"><ellipse cx="9.5" cy="38" rx="2.4" ry="5" transform="rotate(-50 9.5 38)"/><ellipse cx="7.5" cy="29" rx="2.4" ry="5" transform="rotate(-30 7.5 29)"/><ellipse cx="7.8" cy="20" rx="2.3" ry="4.8" transform="rotate(-12 7.8 20)"/><ellipse cx="10" cy="11.5" rx="2.2" ry="4.4" transform="rotate(10 10 11.5)"/><ellipse cx="15.5" cy="38" rx="2.2" ry="4.5" transform="rotate(40 15.5 38)"/><ellipse cx="13" cy="28" rx="2.1" ry="4.3" transform="rotate(30 13 28)"/><ellipse cx="13.2" cy="18.5" rx="2" ry="4" transform="rotate(25 13.2 18.5)"/></g></svg>',
  mask: '<svg viewBox="0 0 64 32" fill="currentColor" aria-hidden="true"><path d="M2 6c10-4 20-2 30 3 10-5 20-7 30-3-1 14-8 22-18 22-6 0-9-4-12-8-3 4-6 8-12 8C10 28 3 20 2 6zm14 6c-4 0-7 2-8 4 3 2 6 3 9 3s5-2 6-4c-2-2-4-3-7-3zm32 0c-3 0-5 1-7 3 1 2 3 4 6 4s6-1 9-3c-1-2-4-4-8-4z"/></svg>',
};
const icon = (name) => el('span', { html: ICON[name], style: { display: 'contents' } });

let token = storage.get();
let view = null;
let screenKey = '';
let showMine = false; // 公開情報卡後，是否切回查看自己的身分卡
let flipping = false;
let watcher = null;


async function init() {
  if (!configured()) return configMissing(app);
  if (!room) return renderMissing('請使用老師提供的 QR Code 進入連線任務。');
  try {
    if (!(await rpc('c606_room_exists', { p_code: room }))) return renderMissing('找不到這個課堂，請重新掃描老師提供的 QR Code。');
  } catch (err) {
    return renderMissing(err.message);
  }
  if (token) connect();
  else renderLogin();
}

function connect() {
  watcher?.stop();
  watcher = watchRoom(room, {
    as: 'student',
    cred: token,
    presenceId: () => view?.me?.id || null,
    onState: (v) => { view = v; render(); },
    onGone: () => { storage.clear(); token = null; screenKey = ''; renderLogin(); },
  });
}

function renderMissing(msg) {
  app.replaceChildren(el('main', { class: 's-screen' }, crest(), el('h1', { class: 'title-606 gold-text' }, '606 情報局'), el('p', { class: 'missing-room' }, msg)));
}

// ─────────────── 登入 ───────────────
function renderLogin() {
  screenKey = 'login';
  updateGate();
  let group = null;
  const nameInput = el('input', { class: 'name-input', id: 'name', name: 'name', maxlength: '12', autocomplete: 'off', placeholder: '請輸入你的姓名', enterkeyhint: 'done' });
  const err = el('p', { class: 'login-error', role: 'alert' });
  const groupBtns = [1, 2, 3, 4, 5, 6].map((g) =>
    el('button', { type: 'button', class: 'group-btn', role: 'radio', 'aria-checked': 'false', 'aria-label': `第 ${g} 組`, 'data-group': g, onclick: () => pick(g) }, pad2(g)),
  );
  const submit = el('button', { type: 'submit', class: 'btn-gold join-btn' }, icon('radio'), '加入情報任務');
  function pick(g) {
    group = g;
    groupBtns.forEach((b) => b.setAttribute('aria-checked', String(Number(b.dataset.group) === g)));
  }
  const form = el('form', { class: 'login-card', novalidate: true, onsubmit: onSubmit },
    el('label', { for: 'name' }, icon('user'), '情報員姓名'),
    nameInput,
    el('div', { class: 'field-label', id: 'glabel' }, icon('group'), '選擇所屬組別'),
    el('div', { class: 'groups', role: 'radiogroup', 'aria-labelledby': 'glabel' }, groupBtns),
    submit,
    err,
  );
  async function onSubmit(e) {
    e.preventDefault();
    err.textContent = '';
    const name = nameInput.value.trim();
    if (!name) { err.textContent = '請輸入你的姓名'; return nameInput.focus(); }
    if (!group) { err.textContent = '請點選你的組別'; return; }
    // 在這次點擊中立即請求全螢幕（之後才進行報到，避免失去使用者手勢）
    if (fs.supported() && !fs.active()) fs.request().catch(() => { fsFailed = true; updateGate(); });
    submit.disabled = true;
    try {
      const res = await rpc('c606_join', { p_code: room, p_name: name, p_group: group });
      token = res.token;
      storage.set(token);
      connect();
    } catch (ex) {
      err.textContent = ex.message;
      submit.disabled = false;
    }
  }
  app.replaceChildren(el('main', { class: 's-screen login' },
    crest(),
    el('h1', { class: 'title-606 gold-text' }, '606 情報局'),
    el('div', { class: 'ribbon' }, '連線任務'),
    form,
  ));
}

// ─────────────── 主畫面 ───────────────
function idLine(v) {
  return el('div', { class: 'sub-id' }, `情報員：${v.me.name}｜第 ${pad2(v.me.group)} 組`);
}

function screenFor(v) {
  if (v.phase === 'lobby' || !v.card) return 'wait';
  if (v.phase === 'identity' || v.phase === 'dice') return 'identity';
  if (v.phase === 'card' || v.phase === 'guess') return showMine ? 'identity' : 'board';
  if (v.phase === 'ending') return 'ending';
  return 'wait';
}

function render() {
  const v = view;
  if (v.phase === 'lobby') showMine = false;
  const scr = screenFor(v);
  const key = `${scr}:${v.roundNo}:${v.phase === 'guess' ? 'g' : ''}`;
  if (key !== screenKey) {
    screenKey = key;
    const build = { wait: buildWait, identity: buildIdentity, board: buildBoard, ending: buildEnding }[scr];
    app.replaceChildren(build(v));
  }
  if (scr === 'identity') patchIdentity(v);
  updateGate();
}

function buildWait(v) {
  const inProgress = v.phase !== 'lobby';
  return el('main', { class: 's-screen wait' },
    icon('shield'),
    el('div', { class: 'top' }, '606 情報局｜連線任務'),
    idLine(v),
    el('div', { class: 'divider' }),
    el('h1', {}, el('span', { class: 'slash' }, '⟋⟋'), '正在等待任務指令⋯', el('span', { class: 'slash' }, '⟋⟋')),
    el('p', { class: 'lead' }, inProgress ? '本輪任務進行中，請留在此畫面，等待下一輪集合。' : ['你已完成報到，請留在此畫面，', el('br'), '等待全體情報員集合。']),
    el('div', { class: 'divider' }),
    el('div', { class: 'next-pill' }, icon('clock'), '下一步：啟動身份認證'),
    el('p', { class: 'note' }, '任務開始後將核對你的身分情報'),
    el('div', { class: 'dots', 'aria-hidden': 'true' }, el('i'), el('i'), el('i')),
  );
}

function buildIdentity(v) {
  const card = el('button', { class: 'flipcard', type: 'button', 'aria-label': '點選卡面確認你的身分', onclick: onFlip },
    el('div', { class: 'inner' },
      el('div', { class: 'face back' }, el('img', { src: 'img/card-back.webp', alt: '身分卡背面' })),
      el('div', { class: 'face front' }, el('img', { alt: '' })),
    ),
  );
  const backToBoard = v.board
    ? el('button', { class: 'mini-link', type: 'button', onclick: () => { showMine = false; render(); } }, '返回公開情報卡')
    : null;
  return el('main', { class: 's-screen idscreen' },
    el('div', { class: 'plaque' }, el('span', { class: 'laurel' }, '❦'), '606 情報局', el('span', { class: 'sep' }), '身份認證', el('span', { class: 'laurel' }, '❦')),
    idLine(v),
    el('div', { class: 'id-main' },
      el('div', { class: 'id-card' }, card),
      el('div', { class: 'id-right' },
        el('div', { class: 'step-pill', 'data-step': '1' }, el('span', { class: 'num' }, '1'), '點選卡面確認你的身分'),
        el('div', { class: 'step-pill', 'data-step': '2' }, el('span', { class: 'num' }, '2'), '等待老師公布情報代碼'),
        el('div', { class: 'codebox', 'aria-live': 'polite' }),
        backToBoard,
      ),
    ),
  );
}

function setFront(cardData) {
  const img = qs('.flipcard .front img');
  const src = CARD_IMG[cardData.role](cardData.variant);
  if (img.getAttribute('src') !== src) {
    img.src = src;
    img.alt = ROLE_NAME[cardData.role] + '身分卡';
  }
  return img;
}

function patchIdentity(v) {
  const c = v.card;
  const fc = qs('.flipcard');
  if (!fc || !c) return;
  if (c.flipped && c.role) {
    setFront(c);
    if (!flipping) fc.classList.add('flipped');
    fc.disabled = true;
    fc.setAttribute('aria-label', `你的身分：${ROLE_NAME[c.role]}`);
    qs('[data-step="1"]').classList.add('done');
  }
  const box = qs('.codebox');
  if (flipping) return; // 翻牌動畫結束後才顯示金框內容
  const want = codeboxState(c);
  if (box.dataset.state === want) return;
  box.dataset.state = want;
  box.classList.toggle('wide', want.startsWith('spy-'));
  if (want === 'empty') box.replaceChildren();
  else if (want === 'spy-hidden') box.replaceChildren(spyHiddenEl());
  else if (want === 'spy-mission') box.replaceChildren(spyMissionEl());
  else box.replaceChildren(el('div', { class: 'code gold-text' }, c.intel.code));
}

/**
 * 右側金框狀態：
 *   未翻牌（任何身分）          → empty（留白，不透露身分）
 *   臥底已翻牌、代碼未公布       → spy-hidden（機密代碼不對你公開；骰子跳動時也維持）
 *   臥底、伺服器已放行          → spy-mission（與情報員拿到代碼同一時機；伺服器只送 mission 訊號，不含代碼）
 *   情報員／局內人、伺服器已放行 → code:XX
 */
function codeboxState(c) {
  if (!c || !c.flipped || !c.role) return 'empty';
  if (c.role === 'spy') return c.intel && c.intel.mission ? 'spy-mission' : 'spy-hidden';
  return c.intel && c.intel.code ? `code:${c.intel.code}` : 'empty';
}
function spyHiddenEl() {
  return el('div', { class: 'spy-hidden' },
    icon('spy'),
    el('p', { class: 'spy-hidden-text' }, '機密代碼不對你公開'),
    el('div', { class: 'spy-rule', 'aria-hidden': 'true' }),
  );
}
function spyMissionEl() {
  return el('div', { class: 'spy-mission' },
    el('div', { class: 'spy-mission-icon' }, el('i', { class: 'ray l1' }), el('i', { class: 'ray l2' }), icon('spy'), el('i', { class: 'ray r1' }), el('i', { class: 'ray r2' })),
    el('h3', {}, el('span', { class: 'laurel l' }, icon('laurel')), el('span', { class: 'gold-text' }, '機密任務'), el('span', { class: 'laurel r' }, icon('laurel'))),
    el('p', { class: 'spy-lines' }, '你不會收到情報代碼', el('br'), '請保持自然，假裝正在確認情報'),
    el('div', { class: 'spy-rule', 'aria-hidden': 'true' }),
    el('p', { class: 'spy-note' }, '仔細聆聽其他情報員的發言'),
  );
}

async function onFlip() {
  const fc = qs('.flipcard');
  if (flipping || fc.classList.contains('flipped')) return;
  flipping = true;
  fc.disabled = true;
  try {
    const v = await rpc('c606_flip', { p_code: room, p_token: token });
    const img = setFront(v.card);
    await (img.decode ? img.decode().catch(() => {}) : Promise.resolve());
    fc.classList.add('flipped');
    setTimeout(() => { flipping = false; watcher.apply(v); render(); }, 950);
  } catch (err) {
    flipping = false;
    fc.disabled = false;
    toast(err.message);
  }
}

function buildBoard(v) {
  const isSpyAccused = v.phase === 'guess' && v.card && v.card.role === 'spy';
  let banner = null;
  if (v.phase === 'guess') {
    banner = isSpyAccused
      ? el('div', { class: 'banner me' }, '你已被指認！請從九個詞語中口頭猜一次機密詞語。')
      : el('div', { class: 'banner' }, `臥底已被指認（第 ${pad2(v.accusedGroup)} 組），臥底將口頭猜一次。`);
  }
  return el('main', { class: 's-screen boardscreen' },
    el('div', { class: 'plaque' }, el('span', { class: 'laurel' }, '❦'), '606 情報局', el('span', { class: 'laurel' }, '❦')),
    el('div', { class: 'deck-title' }, v.board.title),
    boardEl(v.board),
    banner,
    el('button', { class: 'mini-link', type: 'button', onclick: () => { showMine = true; render(); } }, '查看我的身分卡'),
  );
}

function buildEnding(v) {
  return el('main', { class: 's-screen endscreen' },
    endingArtEl(v.ending),
    endingRevealEl(v.ending),
    el('p', { class: 'hint' }, '請等待老師開始下一輪'),
  );
}

// ─────────────── 全螢幕與遮罩（只用於學生端） ───────────────
// 已報到的學生不在全螢幕時，用遮罩蓋住身分卡、代碼與任務內容。
// 遮罩期間仍持續接收教師操作；回到全螢幕後直接看到最新階段。
const fsKey = (k) => `intel606c:${k}:${room}`;
const session = {
  get(k) { try { return sessionStorage.getItem(fsKey(k)) === '1'; } catch { return false; } },
  set(k) { try { sessionStorage.setItem(fsKey(k), '1'); } catch {} },
};
const fs = {
  supported() {
    const d = document.documentElement;
    return !!((document.fullscreenEnabled || document.webkitFullscreenEnabled) && (d.requestFullscreen || d.webkitRequestFullscreen));
  },
  active: () => !!(document.fullscreenElement || document.webkitFullscreenElement),
  /** 回傳 Promise；舊版 webkit API 沒有 Promise，改以短暫等待後檢查結果 */
  request() {
    const d = document.documentElement;
    try {
      const p = d.requestFullscreen ? d.requestFullscreen({ navigationUI: 'hide' }) : d.webkitRequestFullscreen();
      if (p && typeof p.then === 'function') return p;
    } catch (err) {
      return Promise.reject(err);
    }
    return new Promise((ok, fail) => setTimeout(() => (fs.active() ? ok() : fail(new Error('fullscreen denied'))), 900));
  },
};
let fsEver = session.get('fsever'); // 本分頁曾經進入全螢幕 → 按鈕顯示「回到全螢幕」
let fsSkip = session.get('fsskip'); // 學生選擇「以一般畫面繼續」
let fsFailed = false;
let gate = null;
let gateKey = '';

function updateGate() {
  const joined = !!token && screenKey !== 'login' && screenKey !== '' && !!view;
  const show = joined && !fsSkip && !fs.active();
  if (!show) {
    if (gate) { gate.remove(); gate = null; gateKey = ''; }
    return;
  }
  const mode = !fs.supported() ? 'unsupported' : fsFailed ? 'failed' : fsEver ? 'back' : 'enter';
  if (gate && gateKey === mode) return;
  gateKey = mode;
  gate?.remove();
  const goFull = () => {
    fs.request().then(() => { fsFailed = false; updateGate(); }).catch(() => { fsFailed = true; updateGate(); });
  };
  const plain = () => { fsSkip = true; session.set('fsskip'); updateGate(); };
  let body;
  if (mode === 'back' || mode === 'enter') {
    body = [
      el('p', { class: 'gate-title' }, mode === 'back' ? '請回到全螢幕，繼續任務' : '請進入全螢幕，開始任務'),
      el('button', { type: 'button', class: 'btn-gold gate-btn', id: 'fsBtn', onclick: goFull }, mode === 'back' ? '回到全螢幕' : '進入全螢幕'),
    ];
  } else {
    body = [
      el('p', { class: 'gate-title' }, mode === 'unsupported' ? '這台裝置不支援網頁全螢幕' : '瀏覽器沒有開啟全螢幕'),
      el('p', { class: 'gate-note' }, '可以用一般畫面繼續任務，請注意不要讓旁人看到你的平板。'),
      mode === 'failed' ? el('button', { type: 'button', class: 'btn-gold gate-btn', id: 'fsBtn', onclick: goFull }, '再試一次') : null,
      el('button', { type: 'button', class: mode === 'failed' ? 'btn-line gate-plain' : 'btn-gold gate-btn', id: 'fsPlain', onclick: plain }, '以一般畫面繼續'),
    ];
  }
  gate = el('div', { class: 'fs-gate', role: 'dialog', 'aria-modal': 'true', 'aria-label': '全螢幕提示' }, el('div', { class: 'gate-box' }, body));
  document.body.append(gate);
  gate.querySelector('button')?.focus({ preventScroll: true });
}

for (const ev of ['fullscreenchange', 'webkitfullscreenchange']) {
  document.addEventListener(ev, () => {
    if (fs.active()) { fsEver = true; fsFailed = false; session.set('fsever'); }
    updateGate();
  });
}

init();

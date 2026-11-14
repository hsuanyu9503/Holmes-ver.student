// 三種畫面共用的工具：DOM、API、即時同步、情報卡與結局元件。

export const qs = (sel, root = document) => root.querySelector(sel);

/** el('div', {class:'x', onclick}, child, 'text', [more]) */
export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(node.style, v);
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else if (k === 'html') node.innerHTML = v; // 僅用於本檔內建常數
    else if (v === true) node.setAttribute(k, '');
    else node.setAttribute(k, v);
  }
  append(node, children);
  return node;
}
function append(node, children) {
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

export const pad2 = (n) => String(n).padStart(2, '0');
export const roomFromUrl = () => (new URLSearchParams(location.search).get('room') || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

// ─────────────── Supabase 連線 ───────────────
const CFG = window.INTEL606_CONFIG || {};
let client = null;
export const configured = () => !!(CFG.supabaseUrl && CFG.supabaseAnonKey && window.supabase);
function sb() {
  if (!client) {
    if (!configured()) throw Object.assign(new Error('網站尚未設定 Supabase 連線（config.js）'), { status: 0 });
    client = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
  }
  return client;
}

/** 呼叫資料庫函式。錯誤碼 PT401／PT403／PT404／PT409 轉為 status。 */
export async function rpc(fn, args = {}) {
  let res;
  try {
    res = await sb().rpc(fn, args);
  } catch (err) {
    throw Object.assign(new Error('連線失敗，請檢查網路後再試'), { status: 0, cause: err });
  }
  if (res.error) {
    const m = /^PT(\d{3})$/.exec(res.error.code || '');
    const status = m ? Number(m[1]) : res.error.code ? 400 : 0;
    throw Object.assign(new Error(status ? res.error.message : '連線失敗，請檢查網路後再試'), { status });
  }
  return res.data;
}

/** 網站對外網址（QR Code 用）。可在 config.js 設定 publicBaseUrl。 */
export function pageUrl(page) {
  const base = CFG.publicBaseUrl ? CFG.publicBaseUrl.replace(/\/?$/, '/') : new URL('.', location.href).href;
  return new URL(page, base).href;
}

/** 伺服器時間差（毫秒）：serverNow - Date.now() */
export const clock = { offset: 0, now: () => Date.now() + clock.offset };

/**
 * 訂閱課堂畫面資料：
 *   1. Supabase Realtime 收到 c606_signals 版本變動 → 重新讀取本人可見的畫面資料（c606_view）
 *   2. 骰子動畫結束時間（wakeAt）到時自動重讀，取得剛放行的代碼
 *   3. 備援輪詢：Realtime 未連上每 2 秒、連上後每 15 秒
 * opts: {as, cred, onState, onGone, presenceId(): string|null, onPresence(Set<studentId>)}
 */
export function watchRoom(code, opts) {
  const badge = el('div', { class: 'conn off' }, '連線中');
  document.body.append(badge);
  let version = -1;
  let stopped = false;
  let inflight = false;
  let again = false;
  let subscribed = false;
  let tracked = null;
  let wakeTimer = null;
  let pollTimer = null;

  const setBadge = (ok) => {
    badge.className = ok ? 'conn' : 'conn off';
    badge.textContent = ok ? (subscribed ? '已連線' : '已連線（輪詢）') : '重新連線中⋯';
  };
  const apply = (v) => {
    if (!v || v.version < version) return;
    version = v.version;
    clock.offset = v.serverNow - Date.now();
    clearTimeout(wakeTimer);
    if (v.wakeAt) wakeTimer = setTimeout(refresh, Math.max(0, v.wakeAt - clock.now()) + 80);
    opts.onState(v);
    ensureTrack();
  };

  async function refresh() {
    if (stopped) return;
    if (inflight) { again = true; return; }
    inflight = true;
    try {
      apply(await rpc('c606_view', { p_code: code, p_as: opts.as, p_cred: opts.cred ?? null }));
      setBadge(true);
    } catch (err) {
      if ([401, 403, 404].includes(err.status)) { stop(); opts.onGone?.({ error: err.message, status: err.status }); return; }
      setBadge(false);
    } finally {
      inflight = false;
      if (again) { again = false; refresh(); }
    }
  }

  let channel = null;
  async function ensureTrack() {
    const id = opts.presenceId?.();
    if (!channel || !subscribed || !id || tracked === id) return;
    tracked = id;
    try { await channel.track({ sid: id }); } catch {}
  }
  try {
    channel = sb().channel(`c606:${code}`);
    channel.on('postgres_changes', { event: '*', schema: 'public', table: 'c606_signals', filter: `room_code=eq.${code}` }, () => refresh());
    if (opts.onPresence) {
      channel.on('presence', { event: 'sync' }, () => {
        const ids = new Set();
        for (const metas of Object.values(channel.presenceState())) for (const m of metas) if (m.sid) ids.add(m.sid);
        opts.onPresence(ids);
      });
    }
    channel.subscribe((status) => {
      subscribed = status === 'SUBSCRIBED';
      if (subscribed) { tracked = null; ensureTrack(); refresh(); }
      setBadge(true);
    });
  } catch {}

  const loop = () => { pollTimer = setTimeout(() => { refresh(); loop(); }, subscribed ? 15000 : 2000); };
  loop();
  refresh();
  const onVisible = () => document.visibilityState === 'visible' && refresh();
  document.addEventListener('visibilitychange', onVisible);
  window.addEventListener('online', refresh);

  function stop() {
    stopped = true;
    clearTimeout(wakeTimer);
    clearTimeout(pollTimer);
    document.removeEventListener('visibilitychange', onVisible);
    window.removeEventListener('online', refresh);
    if (channel) try { sb().removeChannel(channel); } catch {}
    badge.remove();
  }
  return { refresh, apply, stop };
}

/** 學生報到 QR Code（qrcode-generator，GIF data URL） */
export function qrDataUrl(text) {
  const qr = window.qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  return qr.createDataURL(10, 2);
}

/** 尚未設定 Supabase 時顯示的提示 */
export function configMissing(root) {
  root.replaceChildren(el('main', { class: 's-screen' },
    el('h1', { class: 'title-606 gold-text' }, '606 情報局'),
    el('p', { class: 'missing-room' }, '網站尚未設定 Supabase 連線。請依 README 建立 config.js（填入 Supabase Project URL 與 anon key）。'),
  ));
}

let toastTimer;
export function toast(msg, ok = false) {
  document.querySelectorAll('.toast').forEach((t) => t.remove());
  const t = el('div', { class: 'toast' + (ok ? ' ok' : ''), role: 'status' }, msg);
  document.body.append(t);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.remove(), 3800);
}

export const CREST_SVG = `<svg class="crest" viewBox="0 0 64 64" aria-hidden="true"><defs><linearGradient id="cg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f6dc9f"/><stop offset=".6" stop-color="#d8b06a"/><stop offset="1" stop-color="#9c6f2c"/></linearGradient></defs><circle cx="32" cy="32" r="22" fill="#0c2a2f" stroke="url(#cg)" stroke-width="2.5"/><circle cx="32" cy="32" r="16.5" fill="none" stroke="url(#cg)" stroke-width="1" opacity=".7"/><path d="M32 4 L36 28 L60 32 L36 36 L32 60 L28 36 L4 32 L28 28 Z" fill="url(#cg)"/><path d="M32 16 L34 30 L48 32 L34 34 L32 48 L30 34 L16 32 L30 30 Z" fill="#0c2a2f" opacity=".55"/><circle cx="32" cy="32" r="3" fill="#f6dc9f"/></svg>`;
export const crest = () => el('div', { html: CREST_SVG });

/** 3×3 情報卡。opts: {answer, guess, onPick, picked, showTags} */
export function boardEl(board, opts = {}) {
  const grid = el('div', { class: 'board' });
  grid.append(el('div', { class: 'corner' }));
  for (const c of board.cols) grid.append(el('div', { class: 'colh' }, c));
  board.rows.forEach((r, ri) => {
    grid.append(el('div', { class: 'rowh' }, r));
    board.cols.forEach((c, ci) => {
      const code = `${c}${r}`;
      const word = board.words[ri * 3 + ci];
      const cls = ['cell'];
      if (opts.answer === code) cls.push('answer');
      if (opts.guess === code && opts.answer !== code) cls.push('guess-wrong');
      if (opts.picked === code) cls.push('pick');
      const tag = opts.onPick ? 'button' : 'div';
      const attrs = { class: cls.join(' '), 'data-code': code };
      if (opts.onPick) attrs.onclick = () => opts.onPick(code, word);
      grid.append(el(tag, attrs, opts.showTags ? el('span', { class: 'tag' }, code) : null, word));
    });
  });
  return el('div', { class: 'board-wrap' }, grid);
}

/** 結局畫面（圖 10～12），以面板覆蓋圖上的原標語，確保文字與本輪結果一致。 */
export function endingArtEl(ending) {
  const side = ending.img === 'end-agents' ? 'left' : 'right';
  const isReverse = ending.type === 'spy_reverse';
  return el('div', { class: 'ending-art', 'data-ending': ending.type },
    el('img', { src: `img/${ending.img}.webp`, alt: '' }),
    el('div', { class: `ending-panel ${side}${isReverse ? ' reverse' : ''}` },
      el('div', { class: 'laurels', 'aria-hidden': 'true' }, '❦ ✦ ❦'),
      el('h2', { class: 'gold-text' }, ending.title),
      el('p', { class: 'reason' }, ending.reason),
    ),
  );
}

export function endingRevealEl(ending) {
  return el('div', { class: 'ending-reveal' },
    ending.spy ? el('span', {}, '臥底：', el('b', {}, `第 ${pad2(ending.spy.group)} 組 ${ending.spy.name}`)) : null,
    el('span', {}, '機密情報：', el('b', {}, `${ending.secretCode}「${ending.secretWord}」`)),
    ending.guessCode ? el('span', {}, '臥底猜測：', el('b', {}, `「${ending.guessWord}」`)) : null,
  );
}

export const CARD_IMG = {
  agent: (v) => `img/agent-${v || 'm'}.webp`,
  spy: (v) => `img/spy-${v || 'm'}.webp`,
  insider: () => 'img/insider.webp',
};
export const ROLE_NAME = { agent: '情報員', spy: '臥底', insider: '局內人（觀察員）' };

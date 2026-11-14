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

export async function api(path, body) {
  const res = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let data = {};
  try { data = await res.json(); } catch {}
  if (!res.ok) throw Object.assign(new Error(data.error || '連線失敗，請稍後再試'), { status: res.status });
  return data;
}

/** 伺服器時間差（毫秒）：serverNow - Date.now() */
export const clock = { offset: 0, now: () => Date.now() + clock.offset };

/**
 * 透過 Server-Sent Events 訂閱畫面資料；斷線會自動重連。
 * onState(view) 每次資料變動都會呼叫；onGone(err) 表示憑證失效。
 */
export function subscribe(url, { onState, onGone }) {
  const badge = el('div', { class: 'conn off' }, '連線中');
  document.body.append(badge);
  let es;
  let retry = 0;
  const open = () => {
    es = new EventSource(url);
    es.addEventListener('state', (e) => {
      retry = 0;
      badge.className = 'conn';
      badge.textContent = '已連線';
      const view = JSON.parse(e.data);
      clock.offset = view.serverNow - Date.now();
      onState(view);
    });
    es.addEventListener('gone', (e) => {
      es.close();
      onGone?.(JSON.parse(e.data));
    });
    es.onerror = async () => {
      badge.className = 'conn off';
      badge.textContent = '重新連線中⋯';
      if (es.readyState === EventSource.CLOSED) {
        // 伺服器回應錯誤（例如憑證失效）時 EventSource 不會自動重試
        es.close();
        const probe = url.replace('/events?', '/state?');
        try {
          await api(probe);
        } catch (err) {
          if (err.status === 401 || err.status === 403 || err.status === 404) return onGone?.({ error: err.message, status: err.status });
        }
        setTimeout(open, Math.min(8000, 1000 * 2 ** retry++));
      }
    };
  };
  open();
  return () => es && es.close();
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
    el('img', { src: `/img/${ending.img}.webp`, alt: '' }),
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
  agent: (v) => `/img/agent-${v || 'm'}.webp`,
  spy: (v) => `/img/spy-${v || 'm'}.webp`,
  insider: () => '/img/insider.webp',
};
export const ROLE_NAME = { agent: '情報員', spy: '臥底', insider: '局內人（觀察員）' };

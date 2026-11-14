import { el, qs, subscribe, roomFromUrl, pad2, crest, clock, boardEl, endingArtEl, endingRevealEl } from './common.js';

const app = qs('#app');
const room = roomFromUrl();
let screenKey = '';
let diceTimer = null;

const fsBtn = el('button', { class: 'btn-line fs-btn', type: 'button', onclick: () => document.documentElement.requestFullscreen?.().catch(() => {}) }, '全螢幕');
document.body.append(fsBtn);
document.addEventListener('fullscreenchange', () => { fsBtn.hidden = !!document.fullscreenElement; });

if (!room) {
  app.replaceChildren(el('main', { class: 'd-screen' }, el('p', { class: 'd-msg' }, '請由教師控制台開啟投影畫面。')));
} else {
  subscribe(`/api/rooms/${room}/events?as=display`, {
    onState: render,
    onGone: () => app.replaceChildren(el('main', { class: 'd-screen' }, el('p', { class: 'd-msg' }, '找不到這個課堂。'))),
  });
}

const top = () => el('div', { class: 'd-top' }, crest(), el('div', { class: 'plaque' }, el('span', { class: 'laurel' }, '❦'), '606 情報局', el('span', { class: 'laurel' }, '❦')));

function render(v) {
  const scr = { lobby: 'lobby', identity: 'identity', dice: 'dice', card: 'board', guess: 'board', ending: 'ending' }[v.phase] || 'lobby';
  const key = `${scr}:${v.roundNo}:${v.phase}:${v.dice ? v.dice.rolledAt : ''}`;
  document.body.classList.toggle('lobby', scr === 'lobby');
  if (key !== screenKey) {
    screenKey = key;
    clearInterval(diceTimer);
    app.replaceChildren({ lobby: buildLobby, identity: buildIdentity, dice: buildDice, board: buildBoard, ending: buildEnding }[scr](v));
  }
  if (scr === 'lobby') patchCount(v.count);
  if (scr === 'board') patchStep(v.step);
}

function buildLobby(v) {
  return el('main', { class: 'd-screen' },
    el('div', { class: 'lobby-title rule-title' }, '606 情報局｜任務集結中'),
    el('div', { class: 'count', 'aria-live': 'polite' }, el('span', { class: 'num', 'data-n': v.count }, v.count), el('span', { class: 'unit' }, '人')),
  );
}
function patchCount(n) {
  const num = qs('.count .num');
  if (!num || Number(num.dataset.n) === n) return;
  num.dataset.n = n;
  num.textContent = n;
  num.classList.remove('bump');
  void num.offsetWidth;
  num.classList.add('bump');
}

function buildIdentity() {
  return el('main', { class: 'd-screen' },
    el('div', { class: 'auth-glow' }),
    top(),
    el('div', { class: 'plaque auth-plaque' }, '正在啟動身份認證⋯'),
    el('div', { class: 'auth-bar', role: 'progressbar', 'aria-label': '身份認證進度' }, el('i')),
  );
}

function buildDice(v) {
  const d = v.dice;
  const blue = el('div', { class: 'die blue' }, '1');
  const red = el('div', { class: 'die red' }, '1');
  const val = el('div', { class: 'val' });
  const hint = el('div', { class: 'dice-hint pending' }, '請私下查看平板上的任務資訊');
  const land = () => {
    clearInterval(diceTimer);
    blue.textContent = d.blue;
    red.textContent = d.red;
    blue.classList.remove('rolling'); red.classList.remove('rolling');
    blue.classList.add('landed'); red.classList.add('landed');
    val.replaceChildren(el('span', { class: 'b' }, `藍 ${d.blue}`), el('span', { class: 's' }, '／'), el('span', { class: 'r' }, `紅 ${d.red}`));
    hint.classList.remove('pending');
  };
  if (clock.now() >= d.revealAt) land();
  else {
    blue.classList.add('rolling'); red.classList.add('rolling');
    val.textContent = '擲骰中⋯';
    const faces = [1, 1, 2, 2, 3, 3];
    diceTimer = setInterval(() => {
      if (clock.now() >= d.revealAt) return land();
      blue.textContent = 1 + Math.floor(Math.random() * 6);
      red.textContent = faces[Math.floor(Math.random() * 6)];
    }, 85);
  }
  return el('main', { class: 'd-screen diced' },
    top(),
    el('div', { class: 'dice-row' },
      el('div', { class: 'dice-col' }, blue, el('div', { class: 'dice-label blue' }, '藍色六面骰（1～6）')),
      el('div', { class: 'dice-col' }, red, el('div', { class: 'dice-label red' }, '紅色六面骰（1～3，各兩面）')),
    ),
    el('div', { class: 'dice-result' }, el('div', { class: 'cap' }, '本輪公開骰子點數：'), val),
    hint,
  );
}

const STEPS = [['speak', '① 輪流發言'], ['vote', '② 指認投票'], ['guess', '③ 最後一猜']];
function buildBoard(v) {
  const strip = el('div', { class: 'progress-strip' });
  STEPS.forEach(([k, label], i) => {
    if (i) strip.append(el('span', { class: 'line' }));
    strip.append(el('span', { class: 'st', 'data-step': k }, label));
  });
  return el('main', { class: 'd-screen boardd' },
    top(),
    el('div', { class: 'deck-title' }, v.board.title),
    boardEl(v.board),
    v.phase === 'guess'
      ? el('div', { class: 'guess-banner' }, `臥底被指認！第 ${pad2(v.accusedGroup)} 組請從九個詞語中口頭猜一次`)
      : strip,
  );
}
function patchStep(step) {
  const s = step === 'revote' ? 'vote' : step;
  document.querySelectorAll('.progress-strip .st').forEach((n) => n.classList.toggle('on', n.dataset.step === s));
}

function buildEnding(v) {
  return el('main', { class: 'd-screen endd' }, endingArtEl(v.ending), endingRevealEl(v.ending));
}

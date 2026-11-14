import { el, qs, rpc, toast, watchRoom, configured, configMissing, pageUrl, qrDataUrl, roomFromUrl, pad2, crest, clock, boardEl, endingRevealEl } from './common.js';

const app = qs('#app');
const room = roomFromUrl();
const keyStore = `intel606c:t:${room}`;
let key = null;
let view = null;
let panelKey = '';
let manage = false;
let picked = null; // 最後一猜：老師點選的詞語
let busy = false;
let watcher = null;
let online = new Set();
const draft = { title: '', words: Array(9).fill('') };

init();

function init() {
  if (!configured()) return configMissing(app);
  const hashKey = new URLSearchParams(location.hash.slice(1)).get('k');
  try {
    if (hashKey) localStorage.setItem(keyStore, hashKey);
    key = hashKey || localStorage.getItem(keyStore);
  } catch {
    key = hashKey;
  }
  if (hashKey) history.replaceState(null, '', location.pathname + location.search);
  if (!room || !key) {
    app.replaceChildren(el('main', { class: 'card-p', style: { maxWidth: '560px', margin: '12vh auto' } },
      el('h2', {}, '無法開啟課堂控制台'),
      el('p', {}, '這台裝置沒有此課堂的教師金鑰。請回到首頁建立新課堂，或使用建立課堂時的「教師控制台連結」開啟。'),
      el('a', { class: 'btn-gold', href: 'index.html', style: { textAlign: 'center', textDecoration: 'none' } }, '回到首頁'),
    ));
    return;
  }
  app.replaceChildren(
    el('header', { class: 't-bar', id: 'bar' }),
    el('div', { class: 't-main' }, el('section', { class: 't-groups', id: 'groups' }), el('aside', { class: 't-panel', id: 'panel' })),
  );
  watcher = watchRoom(room, {
    as: 'teacher',
    cred: key,
    onState: (v) => { view = v; render(); },
    onPresence: (ids) => { online = ids; if (view) { renderGroups(); renderBar(); } },
    onGone: (e) => {
      app.replaceChildren(el('main', { class: 'card-p', style: { maxWidth: '560px', margin: '12vh auto' } },
        el('h2', {}, '課堂已失效'), el('p', {}, e.error || '找不到這個課堂或教師金鑰錯誤。'),
        el('a', { class: 'btn-gold', href: 'index.html', style: { textAlign: 'center', textDecoration: 'none' } }, '回到首頁')));
    },
  });
}

async function act(action, payload = {}) {
  if (busy) return;
  busy = true;
  try {
    watcher.apply(await rpc('c606_teacher', { p_code: room, p_key: key, p_action: action, p_payload: payload }));
    return true;
  } catch (err) {
    toast(err.message);
    return false;
  } finally {
    busy = false;
  }
}

const PHASE_LABEL = { lobby: '報到與選人', identity: '身分認證', dice: '擲骰', card: '公開情報卡', guess: '最後一猜', ending: '結局' };

function render() {
  renderBar();
  renderGroups();
  renderPanel();
}

function renderBar() {
  const v = view;
  qs('#bar').replaceChildren(
    el('div', { class: 't-brand' }, crest(), '606 情報局｜課堂控制台'),
    el('span', { class: 'chip' }, '房間碼 ', el('b', { class: 'mono' }, v.code)),
    el('span', { class: 'chip' }, `第 ${v.roundNo} 輪｜${PHASE_LABEL[v.phase]}`),
    el('span', { class: 'chip', id: 'count' }, '報到 ', el('b', {}, v.count), ' 人'),
    el('button', { class: 'btn-line', type: 'button', onclick: showQr }, 'QR Code'),
    el('button', { class: 'btn-line', type: 'button', onclick: showLinks }, '投影畫面'),
  );
}

function renderGroups() {
  const v = view;
  const lobby = v.phase === 'lobby';
  const chosen = lobby ? v.selection : v.players || {};
  const cols = [1, 2, 3, 4, 5, 6].map((g) => {
    const list = v.students.filter((s) => s.group === g);
    const selId = chosen[g];
    const sel = list.find((s) => s.id === selId);
    const col = el('div', { class: 'gcol' + (sel ? ' ready' : ''), 'data-group': g },
      el('div', { class: 'ghead' }, `第 ${pad2(g)} 組`, el('small', {}, `${list.length} 人`)),
      el('div', { class: 'gsel' }, sel ? ['本輪玩家：', el('b', {}, sel.name)] : lobby ? '請點選一位玩家' : ''),
    );
    const ul = el('div', { class: 'glist' });
    if (!list.length) ul.append(el('div', { class: 'empty' }, '尚無學生報到'));
    for (const s of list) {
      const isSel = s.id === selId;
      const b = el('button', {
        class: 'stu' + (isSel ? ' sel' : ''),
        type: 'button',
        'data-id': s.id,
        'aria-pressed': String(isSel),
        disabled: !lobby && !manage,
        onclick: () => lobby && !manage && act('select', { group: g, studentId: isSel ? null : s.id }),
      }, el('span', { class: 'dot' + (online.has(s.id) ? ' on' : ''), title: online.has(s.id) ? '在線' : '離線' }), s.name);
      if (!lobby && (s.isPlayer || s.flipped)) b.append(el('span', { class: 'flip' + (s.flipped ? ' yes' : '') }, s.flipped ? '已翻牌' : '未翻牌'));
      if (manage) {
        const m = el('span', { class: 'mgmt' });
        if (!(s.isPlayer && !lobby)) m.append(el('span', { onclick: (e) => { e.stopPropagation(); confirmBox('移除學生', `確定把「${s.name}」（第 ${g} 組）移出名單？學生需重新掃碼報到。`, () => act('remove', { studentId: s.id })); } }, '移除'));
        m.append(el('span', { class: s.reclaimable ? 'relock' : '', onclick: (e) => { e.stopPropagation(); act('unlock', { studentId: s.id }).then((ok) => ok && toast(`已允許「${s.name}」用相同姓名與組別重新登入`, true)); } }, s.reclaimable ? '可重新登入' : '允許重新登入'));
        b.append(m);
      }
      ul.append(b);
    }
    col.append(ul);
    return col;
  });
  qs('#groups').replaceChildren(...cols);
}

function renderPanel() {
  const v = view;
  const pk = JSON.stringify([v.phase, v.roundNo, v.selection, v.progress, v.dice && v.dice.revealed, v.step, v.deckChoice, v.customDeck, v.accusedGroup, v.ending && v.ending.type, picked, manage, v.players && v.students.filter((s) => s.isPlayer).map((s) => s.name), v.history.length]);
  if (pk === panelKey) return;
  panelKey = pk;
  if (v.phase !== 'guess') picked = null;
  const build = { lobby: panelLobby, identity: panelIdentity, dice: panelDice, card: panelCard, guess: panelGuess, ending: panelEnding }[v.phase];
  const parts = [build(v)];
  if (v.phase !== 'lobby' && v.phase !== 'ending') {
    parts.push(el('button', { class: 'danger-link', type: 'button', onclick: () => confirmBox('作廢本輪', '本輪身分、翻牌、骰點與情報卡都會清除，回到選人畫面（同一輪次重新開始）。確定嗎？', () => act('abort')) }, '作廢本輪，回到選人'));
  }
  parts.push(el('button', { class: 'danger-link', style: { color: 'var(--muted)' }, type: 'button', onclick: () => { manage = !manage; panelKey = ''; render(); } }, manage ? '完成名單管理' : '名單管理（移除／允許重新登入）'));
  qs('#panel').replaceChildren(...parts);
}

const nameOfGroup = (g) => {
  const id = (view.players || view.selection)[g];
  const s = view.students.find((x) => x.id === id);
  return s ? s.name : '';
};

function panelLobby(v) {
  const missing = [1, 2, 3, 4, 5, 6].filter((g) => !v.selection[g]);
  const ready = missing.length === 0;
  const select = el('select', { id: 'deck', onchange: (e) => onDeck(e.target.value) },
    el('option', { value: 'auto', selected: v.deckChoice === 'auto' }, '自動輪替（每輪換主題）'),
    v.decks.map((d) => el('option', { value: d.id, selected: v.deckChoice === d.id }, d.title)),
    el('option', { value: 'custom', selected: v.deckChoice === 'custom' }, v.customDeck ? `自訂：${v.customDeck.title}` : '自訂主題⋯'),
  );
  const deck = v.decks.find((d) => d.id === v.deckChoice) || (v.deckChoice === 'custom' ? v.customDeck : null);
  const customEditor = el('div', { id: 'customEditor', hidden: true, class: 'field' },
    el('input', { placeholder: '主題名稱（最多 8 字）', maxlength: '8', value: draft.title, oninput: (e) => { draft.title = e.target.value; } }),
    el('div', { class: 'custom-grid' }, draft.words.map((w, i) => el('input', { placeholder: ['A1', 'B1', 'C1', 'A2', 'B2', 'C2', 'A3', 'B3', 'C3'][i], maxlength: '6', value: w, oninput: (e) => { draft.words[i] = e.target.value; } }))),
    el('button', { class: 'btn-line', type: 'button', onclick: saveCustom }, '儲存自訂主題'),
  );
  return el('div', { class: 'card-p' },
    el('h2', {}, `第 ${v.roundNo} 輪｜選定六名玩家`),
    el('div', { class: 'meter' }, el('span', { class: 'lab' }, '已選'), el('span', { class: 'val' }, 6 - missing.length, el('small', {}, '／6 組'))),
    el('p', {}, ready ? '六組都已選好玩家，可以啟動身分認證。其餘學生將擔任局內人。' : `請在左側每組點選一名玩家（尚缺第 ${missing.join('、')} 組）。選中的姓名以金色標示，啟動前可改選。`),
    el('label', { class: 'field' }, '情報卡主題', select),
    deck && deck.words ? el('div', { class: 'words-preview' }, deck.words.join('、')) : null,
    customEditor,
    el('button', { class: 'btn-gold big-btn', id: 'startBtn', type: 'button', disabled: !ready, onclick: () => act('start') }, '啟動身分認證'),
    v.history.length ? el('div', { class: 'field' }, '過往結果', el('ol', { class: 'history' }, v.history.map((h) => el('li', {}, `第 ${h.no} 輪｜${h.deck}｜${endingShort(h.type)}`)))) : null,
  );
  function onDeck(val) {
    if (val === 'custom') { qs('#customEditor').hidden = false; return; }
    act('deck', { choice: val });
  }
  function saveCustom() {
    act('deck', { choice: 'custom', custom: { title: draft.title.trim(), words: draft.words.map((w) => w.trim()) } }).then((ok) => ok && toast('已套用自訂主題', true));
  }
}
const endingShort = (t) => ({ spy_wrong: '臥底勝利（指認錯人）', spy_tie: '臥底勝利（重投平手）', spy_reverse: '臥底逆轉勝利', agents: '情報員勝利' }[t] || t);

function panelIdentity(v) {
  const p = v.progress;
  const ready = p.playersFlipped === 6;
  return el('div', { class: 'card-p' },
    el('h2', {}, '身分認證｜等待玩家翻牌'),
    el('div', { class: 'meter', id: 'playersMeter' }, el('span', { class: 'lab' }, '玩家已翻牌'), el('span', { class: 'val' }, p.playersFlipped, el('small', {}, `／${p.playersTotal}`))),
    playerList(v),
    el('div', { class: 'meter minor' }, el('span', { class: 'lab' }, '局內人已翻牌（不影響進度）'), el('span', { class: 'val' }, `${p.insidersFlipped}／${p.insidersTotal}`)),
    el('p', {}, ready ? '六名玩家都已翻牌，可以擲骰。' : '六名玩家全部翻牌後才能擲骰。'),
    el('button', { class: 'btn-gold big-btn', id: 'rollBtn', type: 'button', disabled: !ready, onclick: () => act('roll') }, '擲骰'),
  );
}
function playerList(v) {
  return el('div', { class: 'plist' }, [1, 2, 3, 4, 5, 6].map((g) => {
    const s = v.students.find((x) => x.id === v.players[g]);
    return el('div', {}, el('span', {}, `${g}｜${s ? s.name : '—'}`), s && s.flipped ? el('span', { class: 'ok' }, '已翻牌') : el('span', { class: 'no' }, '未翻牌'));
  }));
}
function diceText(d) {
  return el('div', { class: 'dice-mini' }, el('span', { class: 'b' }, `藍 ${d.blue}`), el('span', { class: 's' }, '／'), el('span', { class: 'r' }, `紅 ${d.red}`));
}

function panelDice(v) {
  const revealed = v.dice.revealed || clock.now() >= v.dice.revealAt;
  return el('div', { class: 'card-p' },
    el('h2', {}, '擲骰結果'),
    revealed ? diceText(v.dice) : el('div', { class: 'dice-mini' }, '大螢幕擲骰中⋯'),
    el('p', {}, revealed
      ? '情報員與局內人的平板已顯示本輪代碼，臥底收到機密任務。請先留時間讓學生私下查看平板，再公開情報卡。'
      : '骰子動畫結束後，學生平板會同步顯示私人資訊。'),
    el('button', { class: 'btn-gold big-btn', id: 'publishBtn', type: 'button', disabled: !revealed, onclick: () => act('publish') }, '公開情報卡'),
  );
}

function panelCard(v) {
  const steps = [['speak', '輪流發言'], ['vote', '指認投票'], ['revote', '平手重投']];
  return el('div', { class: 'card-p' },
    el('h2', {}, `發言與投票｜${v.board.title}`),
    v.dice ? diceText(v.dice) : null,
    el('p', {}, '請現場點名六名玩家輪流發言，再由玩家口頭投票。大螢幕持續顯示完整情報卡（下方步驟提示可選擇切換）。'),
    el('div', { class: 'seg' }, steps.map(([k, label]) => el('button', { type: 'button', class: v.step === k ? 'on' : '', onclick: () => act('step', { step: k }) }, label))),
    el('div', { class: 'field' }, '投票結果：最高票的組別（系統判定是否為臥底）'),
    el('div', { class: 'accuse' }, [1, 2, 3, 4, 5, 6].map((g) =>
      el('button', { type: 'button', 'data-accuse': g, onclick: () => confirmBox('確認指認結果', `玩家指認「第 ${g} 組 ${nameOfGroup(g)}」為臥底？確認後由系統判定。`, () => act('accuse', { group: g })) },
        el('b', {}, `第 ${g} 組`), el('span', {}, nameOfGroup(g))))),
    el('button', { class: 'btn-line', id: 'tieBtn', type: 'button', onclick: () => confirmBox('重投後仍平手', '並列玩家已補充發言並重投，結果仍是平手？確認後本輪由臥底獲勝。', () => act('tie')) }, '重投後仍平手 → 臥底勝利'),
  );
}

function panelGuess(v) {
  const word = picked ? v.board.words[['A1', 'B1', 'C1', 'A2', 'B2', 'C2', 'A3', 'B3', 'C3'].indexOf(picked)] : null;
  return el('div', { class: 'card-p' },
    el('h2', {}, '臥底最後一猜'),
    el('p', { class: 'end-reason' }, `第 ${v.accusedGroup} 組 ${nameOfGroup(v.accusedGroup)} 是臥底！請臥底從九個詞語中口頭猜一次，再點選臥底說出的詞語。`),
    boardEl(v.board, { onPick: (code) => { picked = code; panelKey = ''; renderPanel(); }, picked }),
    el('button', { class: 'btn-gold big-btn', id: 'guessBtn', type: 'button', disabled: !picked, onclick: () => act('guess', { code: picked }) }, picked ? `確認猜「${word}」並公布結局` : '請先點選臥底猜的詞語'),
  );
}

function panelEnding(v) {
  const e = v.ending;
  return el('div', { class: 'card-p' },
    el('h2', {}, '本輪結局'),
    el('div', { class: 'end-title gold-text' }, e.title),
    el('p', { class: 'end-reason' }, e.reason),
    endingRevealEl(e),
    boardEl(v.board, { answer: e.secretCode, guess: e.guessCode }),
    el('button', { class: 'btn-gold big-btn', id: 'nextBtn', type: 'button', onclick: () => act('next') }, '下一輪'),
    el('p', {}, '下一輪保留全班報到名單，並預選本輪六名玩家，可再更換。'),
  );
}

// ─────────────── 對話框 ───────────────
function modal(content) {
  const bg = el('div', { class: 'modal-bg', onclick: (e) => e.target === bg && bg.remove() }, content);
  document.body.append(bg);
  return bg;
}
function confirmBox(title, text, onOk) {
  const bg = modal(el('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' },
    el('h3', {}, title), el('p', {}, text),
    el('div', { class: 'row' },
      el('button', { class: 'btn-line', type: 'button', onclick: () => bg.remove() }, '取消'),
      el('button', { class: 'btn-gold', type: 'button', id: 'confirmOk', onclick: () => { bg.remove(); onOk(); } }, '確認'),
    ),
  ));
}
function showQr() {
  const url = pageUrl(`join.html?room=${room}`);
  const bg = modal(el('div', { class: 'modal qr-modal' },
    el('h3', {}, '掃碼加入情報任務'),
    el('img', { src: qrDataUrl(url), alt: '學生報到 QR Code' }),
    el('div', { class: 'url' }, url.replace(/^https?:\/\//, '')),
    el('button', { class: 'btn-line', type: 'button', onclick: () => bg.remove() }, '關閉'),
  ));
}
function showLinks() {
  const screenUrl = pageUrl(`screen.html?room=${room}`);
  const bg = modal(el('div', { class: 'modal' },
    el('h3', {}, '教室大螢幕'),
    el('div', { class: 'links' },
      el('p', {}, '在接投影機的電腦開啟下列網址，按「全螢幕」即可。投影畫面只顯示公開資訊。'),
      el('code', {}, screenUrl),
      el('p', {}, '在其他裝置繼續操作控制台（含教師金鑰，請勿外流）：'),
      el('code', {}, `${pageUrl(`teacher.html?room=${room}`)}#k=${key}`),
    ),
    el('div', { class: 'row' },
      el('a', { class: 'btn-line', href: screenUrl, target: '_blank', rel: 'noopener' }, '在新分頁開啟'),
      el('button', { class: 'btn-gold', type: 'button', onclick: () => bg.remove() }, '關閉'),
    ),
  ));
}

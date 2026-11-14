'use strict';
/**
 * 606 情報局｜近距課堂 — 遊戲核心（純邏輯，無 I/O）。
 *
 * 所有身分、對照表、機密代碼都只存在伺服器的 room 物件中；
 * 前端只會拿到 view*() 依身分過濾後的資料。
 */
const crypto = require('node:crypto');
const { DECKS } = require('./decks');

const GROUPS = [1, 2, 3, 4, 5, 6];
const COLS = ['A', 'B', 'C'];
const ROWS = [1, 2, 3];
// 格位代碼依情報卡閱讀順序：A1 B1 C1 / A2 B2 C2 / A3 B3 C3
const CELL_CODES = ROWS.flatMap((r) => COLS.map((c) => `${c}${r}`));
const RED_FACES = [1, 1, 2, 2, 3, 3]; // 紅骰：1、1、2、2、3、3
const REVEAL_DELAY_MS = 2600; // 投影骰子動畫長度；之後才釋出代碼
const MAX_STUDENTS = 80;
const NAME_MAX = 12;

const SPY_MISSION = '機密任務：觀察其他玩家的發言，推理本輪的機密情報。';

const ENDINGS = {
  spy_wrong: { title: '臥底勝利！', reason: '玩家指認錯人，臥底成功隱藏身分。', img: 'end-spy', winner: 'spy' },
  spy_tie: { title: '臥底勝利！', reason: '再次投票仍平手，臥底成功逃過指認。', img: 'end-spy', winner: 'spy' },
  spy_reverse: { title: '臥底逆轉勝利！', reason: '臥底猜中機密詞語，成功逆轉。', img: 'end-spy-reverse', winner: 'spy' },
  agents: { title: '情報員勝利！', reason: '情報員成功揪出臥底，守住機密詞語。', img: 'end-agents', winner: 'agents' },
};

class GameError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

const rint = (n) => crypto.randomInt(n);
const newToken = (bytes = 18) => crypto.randomBytes(bytes).toString('base64url');

function shuffle(arr) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = rint(i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function newRoomCode() {
  let s = '';
  for (let i = 0; i < 6; i++) s += CODE_ALPHABET[rint(CODE_ALPHABET.length)];
  return s;
}

/** 18 個位置（藍 1～6 列 × 紅 1～3 欄），九個代碼各出現兩次。 */
function makeCodeMap() {
  return shuffle(CELL_CODES.flatMap((c) => [c, c]));
}
function lookup(codeMap, blue, red) {
  return codeMap[(blue - 1) * 3 + (red - 1)];
}
function rollDice() {
  return { blue: rint(6) + 1, red: RED_FACES[rint(6)] };
}

function cleanName(raw) {
  const name = String(raw ?? '').replace(/[\u0000-\u001f\u007f<>]/g, '').replace(/\s+/g, ' ').trim();
  if (!name) throw new GameError('請輸入姓名');
  if ([...name].length > NAME_MAX) throw new GameError(`姓名最多 ${NAME_MAX} 個字`);
  return name;
}
function cleanGroup(raw) {
  const g = Number(raw);
  if (!GROUPS.includes(g)) throw new GameError('請選擇第 1～6 組');
  return g;
}

function createRoom(now = Date.now(), code = newRoomCode()) {
  return {
    code,
    teacherKey: newToken(24),
    createdAt: now,
    updatedAt: now,
    students: {}, // id -> {id,name,group,token,variant,joinedAt,reclaimable}
    order: [],
    selection: emptySelection(),
    deckChoice: 'auto',
    customDeck: null,
    usedDecks: [],
    roundNo: 1,
    phase: 'lobby',
    round: null,
    history: [],
  };
}
function emptySelection() {
  return Object.fromEntries(GROUPS.map((g) => [g, null]));
}

const inRound = (room) => room.phase !== 'lobby' && !!room.round;
const isRevealed = (room, now) => !!(room.round && room.round.dice && now >= room.round.dice.revealAt);
const studentByToken = (room, token) =>
  token ? Object.values(room.students).find((s) => s.token === token) || null : null;

function touch(room, now) {
  room.updatedAt = now;
}

// ───────────────────────── 學生 ─────────────────────────

function join(room, { name, group, token } = {}, now = Date.now()) {
  const existing = studentByToken(room, token);
  if (existing) return existing;

  const n = cleanName(name);
  const g = cleanGroup(group);
  const dup = Object.values(room.students).find(
    (s) => s.group === g && s.name.toLowerCase() === n.toLowerCase(),
  );
  if (dup) {
    if (dup.reclaimable) {
      dup.token = newToken();
      dup.reclaimable = false;
      touch(room, now);
      return dup;
    }
    throw new GameError(`「${n}」已在第 ${g} 組報到。若是本人換了裝置，請老師在名單中按「允許重新登入」。`, 409);
  }
  if (room.order.length >= MAX_STUDENTS) throw new GameError('本課堂報到人數已滿');

  const s = {
    id: newToken(9),
    name: n,
    group: g,
    token: newToken(),
    variant: rint(2) ? 'f' : 'm',
    joinedAt: now,
    reclaimable: false,
  };
  room.students[s.id] = s;
  room.order.push(s.id);
  // 本輪進行中才報到的學生，直接擔任局內人。
  if (inRound(room)) room.round.roles[s.id] = 'insider';
  touch(room, now);
  return s;
}

function flip(room, token, now = Date.now()) {
  const s = studentByToken(room, token);
  if (!s) throw new GameError('找不到報到資料，請重新掃碼', 401);
  if (!inRound(room) || !room.round.roles[s.id]) throw new GameError('身分認證尚未開始');
  if (!room.round.flipped[s.id]) {
    room.round.flipped[s.id] = now;
    touch(room, now);
  }
  return s;
}

// ───────────────────────── 教師 ─────────────────────────

function playerIds(round) {
  return GROUPS.map((g) => round.players[g]);
}
function flipProgress(room) {
  const r = room.round;
  if (!r) return null;
  const pids = playerIds(r);
  const insiders = Object.keys(r.roles).filter((id) => r.roles[id] === 'insider' && room.students[id]);
  return {
    playersFlipped: pids.filter((id) => r.flipped[id]).length,
    playersTotal: pids.length,
    insidersFlipped: insiders.filter((id) => r.flipped[id]).length,
    insidersTotal: insiders.length,
  };
}

function pickDeck(room) {
  if (room.deckChoice === 'custom' && room.customDeck) return { id: 'custom', ...room.customDeck };
  const fixed = DECKS.find((d) => d.id === room.deckChoice);
  if (fixed) return { ...fixed, words: fixed.words.slice() };
  let pool = DECKS.filter((d) => !room.usedDecks.includes(d.id));
  if (!pool.length) pool = DECKS.filter((d) => d.id !== room.usedDecks[room.usedDecks.length - 1]);
  const d = pool[rint(pool.length)];
  return { ...d, words: d.words.slice() };
}

function cleanCustomDeck(input) {
  const title = String(input?.title ?? '').trim();
  if (!title || [...title].length > 8) throw new GameError('自訂主題名稱需為 1～8 個字');
  const words = Array.isArray(input?.words) ? input.words.map((w) => String(w ?? '').trim()) : [];
  if (words.length !== 9 || words.some((w) => !w || [...w].length > 6)) {
    throw new GameError('請填滿九個詞語，每個最多 6 個字');
  }
  if (new Set(words).size !== 9) throw new GameError('九個詞語不可重複');
  return { title, words };
}

function requirePhase(room, ...phases) {
  if (!phases.includes(room.phase)) throw new GameError('目前階段無法執行這個操作', 409);
}

const ACTIONS = {
  select(room, { group, studentId }) {
    requirePhase(room, 'lobby');
    const g = cleanGroup(group);
    if (studentId == null) {
      room.selection[g] = null;
      return;
    }
    const s = room.students[studentId];
    if (!s || s.group !== g) throw new GameError('這位學生不在第 ' + g + ' 組');
    room.selection[g] = s.id;
  },

  deck(room, { choice, custom }) {
    requirePhase(room, 'lobby');
    if (choice === 'custom') {
      room.customDeck = cleanCustomDeck(custom);
      room.deckChoice = 'custom';
    } else if (choice === 'auto' || DECKS.some((d) => d.id === choice)) {
      room.deckChoice = choice;
    } else throw new GameError('找不到這個情報卡主題');
  },

  start(room, _p, now) {
    requirePhase(room, 'lobby');
    const missing = GROUPS.filter((g) => {
      const s = room.students[room.selection[g]];
      return !s || s.group !== g;
    });
    if (missing.length) throw new GameError(`第 ${missing.join('、')} 組尚未選定玩家`);
    const players = { ...room.selection };
    const spyGroup = GROUPS[rint(6)];
    const roles = {};
    for (const id of room.order) roles[id] = 'insider';
    for (const g of GROUPS) roles[players[g]] = g === spyGroup ? 'spy' : 'agent';
    room.round = {
      no: room.roundNo,
      startedAt: now,
      players,
      roles,
      spyId: players[spyGroup],
      flipped: {},
      codeMap: makeCodeMap(),
      deck: pickDeck(room),
      dice: null,
      secretCode: null,
      cardPublic: false,
      step: null,
      accusedGroup: null,
      guessCode: null,
      ending: null,
    };
    room.phase = 'identity';
  },

  roll(room, _p, now) {
    requirePhase(room, 'identity');
    const prog = flipProgress(room);
    if (prog.playersFlipped < 6) throw new GameError(`還有 ${6 - prog.playersFlipped} 名玩家尚未翻牌`);
    const { blue, red } = rollDice();
    const r = room.round;
    r.dice = { blue, red, rolledAt: now, revealAt: now + REVEAL_DELAY_MS };
    r.secretCode = lookup(r.codeMap, blue, red);
    room.phase = 'dice';
  },

  publish(room, _p, now) {
    requirePhase(room, 'dice');
    if (!isRevealed(room, now)) throw new GameError('骰子動畫尚未結束');
    room.round.cardPublic = true;
    room.round.step = 'speak';
    room.phase = 'card';
  },

  step(room, { step }) {
    requirePhase(room, 'card');
    if (!['speak', 'vote', 'revote'].includes(step)) throw new GameError('未知的步驟');
    room.round.step = step;
  },

  accuse(room, { group }, now) {
    requirePhase(room, 'card');
    const g = cleanGroup(group);
    const r = room.round;
    r.accusedGroup = g;
    if (r.players[g] === r.spyId) {
      room.phase = 'guess';
      r.step = 'guess';
    } else endRound(room, 'spy_wrong', now);
  },

  tie(room, _p, now) {
    requirePhase(room, 'card');
    endRound(room, 'spy_tie', now);
  },

  guess(room, { code }, now) {
    requirePhase(room, 'guess');
    if (!CELL_CODES.includes(code)) throw new GameError('請選擇臥底猜的詞語');
    room.round.guessCode = code;
    endRound(room, code === room.round.secretCode ? 'spy_reverse' : 'agents', now);
  },

  next(room) {
    requirePhase(room, 'ending');
    room.usedDecks.push(room.round.deck.id);
    resetToLobby(room, true);
  },

  abort(room) {
    if (!inRound(room)) throw new GameError('目前沒有進行中的回合', 409);
    resetToLobby(room, false);
  },

  remove(room, { studentId }) {
    const s = room.students[studentId];
    if (!s) throw new GameError('找不到這位學生');
    if (inRound(room) && playerIds(room.round).includes(s.id)) throw new GameError('本輪玩家無法移除，請先結束本輪');
    delete room.students[s.id];
    room.order = room.order.filter((id) => id !== s.id);
    for (const g of GROUPS) if (room.selection[g] === s.id) room.selection[g] = null;
    if (room.round) delete room.round.roles[s.id];
  },

  unlock(room, { studentId }) {
    const s = room.students[studentId];
    if (!s) throw new GameError('找不到這位學生');
    s.reclaimable = true;
  },
};

function endRound(room, type, now) {
  const r = room.round;
  r.ending = { type, at: now };
  r.step = null;
  room.phase = 'ending';
  room.history.push({ no: r.no, type, deck: r.deck.title, code: r.secretCode, at: now });
}

function resetToLobby(room, advance) {
  const prev = room.round;
  if (advance) room.roundNo += 1;
  room.round = null;
  room.phase = 'lobby';
  // 預選上一輪的六名玩家（仍在名單中者）
  room.selection = emptySelection();
  if (prev) for (const g of GROUPS) if (room.students[prev.players[g]]) room.selection[g] = prev.players[g];
}

function teacherAction(room, key, action, payload = {}, now = Date.now()) {
  if (!safeEqual(key, room.teacherKey)) throw new GameError('教師金鑰錯誤', 403);
  const fn = ACTIONS[action];
  if (!fn) throw new GameError('未知的操作');
  fn(room, payload || {}, now);
  touch(room, now);
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

// ───────────────────────── 視圖（權限過濾） ─────────────────────────

function wordOf(round, code) {
  const i = CELL_CODES.indexOf(code);
  return i >= 0 ? round.deck.words[i] : null;
}

function publicView(room, now) {
  const r = room.round;
  const view = {
    code: room.code,
    roundNo: room.roundNo,
    phase: room.phase,
    serverNow: now,
    count: room.order.length,
    board: null,
    step: r ? r.step : null,
    accusedGroup: null,
    ending: null,
  };
  if (r && r.cardPublic) {
    view.board = { title: r.deck.title, words: r.deck.words.slice(), cols: COLS, rows: ROWS };
  }
  if (r && (room.phase === 'guess' || room.phase === 'ending')) view.accusedGroup = r.accusedGroup;
  if (r && r.ending) {
    const spy = room.students[r.spyId];
    view.ending = {
      type: r.ending.type,
      ...ENDINGS[r.ending.type],
      spy: spy ? { name: spy.name, group: spy.group } : null,
      spyGroup: GROUPS.find((g) => r.players[g] === r.spyId),
      secretCode: r.secretCode,
      secretWord: wordOf(r, r.secretCode),
      guessCode: r.guessCode,
      guessWord: r.guessCode ? wordOf(r, r.guessCode) : null,
    };
  }
  return view;
}

function publicDice(room, now) {
  const d = room.round && room.round.dice;
  if (!d) return null;
  return { blue: d.blue, red: d.red, rolledAt: d.rolledAt, revealAt: d.revealAt, revealed: now >= d.revealAt };
}

/** 教室大螢幕：只含公開資訊。 */
function viewDisplay(room, now = Date.now()) {
  return { ...publicView(room, now), as: 'display', dice: publicDice(room, now) };
}

/** 教師控制平板：名單、選人、翻牌進度、公開骰點。不含身分分配與機密代碼（結局前）。 */
function viewTeacher(room, now = Date.now(), online = new Set()) {
  const r = room.round;
  const pids = r ? playerIds(r) : [];
  const students = room.order.map((id) => {
    const s = room.students[id];
    return {
      id: s.id,
      name: s.name,
      group: s.group,
      online: online.has(s.id),
      reclaimable: s.reclaimable,
      isPlayer: pids.includes(s.id),
      flipped: !!(r && r.flipped[s.id]),
    };
  });
  return {
    ...publicView(room, now),
    as: 'teacher',
    dice: publicDice(room, now),
    students,
    selection: room.selection,
    players: r ? r.players : null,
    progress: flipProgress(room),
    deckChoice: room.deckChoice,
    customDeck: room.customDeck,
    decks: DECKS.map((d) => ({ id: d.id, title: d.title, words: d.words })),
    roundDeck: r ? { title: r.deck.title, words: r.deck.words.slice() } : null,
    history: room.history.slice(-10),
  };
}

/** 學生平板：只含本人資料；角色要翻牌後才給，代碼要骰子動畫結束後才給。 */
function viewStudent(room, student, now = Date.now()) {
  const r = room.round;
  const base = publicView(room, now);
  const me = { id: student.id, name: student.name, group: student.group };
  const view = { ...base, as: 'student', me, card: null };
  const role = r && inRound(room) ? r.roles[student.id] : null;
  if (role) {
    const flipped = !!r.flipped[student.id];
    view.card = { flipped, role: null, variant: null, intel: null, isPlayer: role !== 'insider' };
    if (flipped) {
      view.card.role = role;
      view.card.variant = role === 'insider' ? null : student.variant;
      if (isRevealed(room, now)) {
        view.card.intel = role === 'spy' ? { mission: SPY_MISSION } : { code: r.secretCode };
      }
    }
  }
  return view;
}

/** 下一次需要主動推播的時間（骰子動畫結束時釋出代碼）。 */
function nextWakeAt(room, now = Date.now()) {
  const d = room.round && room.round.dice;
  return d && now < d.revealAt ? d.revealAt : null;
}

module.exports = {
  GROUPS,
  COLS,
  ROWS,
  CELL_CODES,
  RED_FACES,
  REVEAL_DELAY_MS,
  ENDINGS,
  SPY_MISSION,
  GameError,
  createRoom,
  join,
  flip,
  teacherAction,
  viewDisplay,
  viewTeacher,
  viewStudent,
  studentByToken,
  nextWakeAt,
  makeCodeMap,
  lookup,
  rollDice,
  flipProgress,
  newRoomCode,
};

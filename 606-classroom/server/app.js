'use strict';
/**
 * HTTP + Server-Sent Events 伺服器。
 *
 *   POST /api/rooms                         建立課堂（若設定 TEACHER_PASSCODE 需附上）
 *   GET  /api/rooms/:code                   房間是否存在（學生登入頁用）
 *   POST /api/rooms/:code/join              學生報到 {name, group, token?}
 *   POST /api/rooms/:code/flip              學生翻牌 {token}
 *   POST /api/rooms/:code/teacher           教師操作 {key, action, ...}
 *   GET  /api/rooms/:code/state?as=...      目前畫面資料（一次性）
 *   GET  /api/rooms/:code/events?as=...     即時同步（SSE）
 *   GET  /api/rooms/:code/qr.svg            學生報到 QR Code
 *   GET  /j/:code  /s/:code  /t/:code       學生／投影／教師短網址
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const QRCode = require('qrcode');
const game = require('./game');
const { Store } = require('./store');

const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};
const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy':
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
    "font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'",
};

function createApp(opts = {}) {
  const store = new Store(opts.dataDir === undefined ? null : opts.dataDir);
  store.load();
  const passcode = opts.teacherPasscode || '';
  const publicBaseUrl = (opts.publicBaseUrl || '').replace(/\/+$/, '');
  const now = opts.now || (() => Date.now());

  /** room code -> Set<{res, as, studentId, last}> */
  const subs = new Map();
  const wakeTimers = new Map();

  function onlineSet(code) {
    const set = new Set();
    for (const sub of subs.get(code) || []) if (sub.studentId) set.add(sub.studentId);
    return set;
  }

  function viewFor(room, as, cred, t = now()) {
    if (as === 'display') return game.viewDisplay(room, t);
    if (as === 'teacher') {
      if (!safeKey(cred, room.teacherKey)) throw new game.GameError('教師金鑰錯誤', 403);
      return game.viewTeacher(room, t, onlineSet(room.code));
    }
    if (as === 'student') {
      const s = game.studentByToken(room, cred);
      if (!s) throw new game.GameError('找不到報到資料，請重新掃碼', 401);
      return game.viewStudent(room, s, t);
    }
    throw new game.GameError('未知的畫面類型');
  }

  function broadcast(room) {
    const set = subs.get(room.code);
    const t = now();
    if (set) {
      for (const sub of set) {
        let view;
        try {
          view = viewFor(room, sub.as, sub.cred, t);
        } catch (err) {
          sendEvent(sub.res, 'gone', { error: err.message });
          sub.res.end();
          set.delete(sub);
          continue;
        }
        sendView(sub, view);
      }
    }
    scheduleWake(room);
  }

  function sendView(sub, view) {
    // serverNow 每次都不同，比較時排除
    const { serverNow, ...rest } = view;
    const key = JSON.stringify(rest);
    if (key === sub.last) return;
    sub.last = key;
    sendEvent(sub.res, 'state', view);
  }

  function scheduleWake(room) {
    const at = game.nextWakeAt(room, now());
    const prev = wakeTimers.get(room.code);
    if (prev && prev.at === at) return;
    if (prev) clearTimeout(prev.timer);
    wakeTimers.delete(room.code);
    if (at == null) return;
    const timer = setTimeout(() => {
      wakeTimers.delete(room.code);
      broadcast(room);
    }, Math.max(0, at - now()) + 25);
    timer.unref?.();
    wakeTimers.set(room.code, { at, timer });
  }

  function changed(room) {
    store.save();
    broadcast(room);
  }

  function baseUrl(req) {
    if (publicBaseUrl) return publicBaseUrl;
    const proto = (req.headers['x-forwarded-proto'] || '').split(',')[0].trim() || (req.socket.encrypted ? 'https' : 'http');
    const host = (req.headers['x-forwarded-host'] || req.headers.host || 'localhost').split(',')[0].trim();
    return `${proto}://${host}`;
  }

  // ───────────── handlers ─────────────

  async function handleApi(req, res, url) {
    const parts = url.pathname.split('/').filter(Boolean); // ['api','rooms',code,sub]
    if (parts[1] !== 'rooms') return notFound(res);

    if (parts.length === 2 && req.method === 'POST') {
      const body = await readJson(req);
      if (passcode && !safeKey(body.passcode, passcode)) throw new game.GameError('教師通行碼錯誤', 403);
      let code;
      do code = game.newRoomCode();
      while (store.get(code));
      const room = game.createRoom(now(), code);
      store.add(room);
      return json(res, 201, { code: room.code, teacherKey: room.teacherKey });
    }

    const room = store.get(parts[2]);
    if (!room) throw new game.GameError('找不到這個課堂，請確認 QR Code 或房間碼', 404);
    const sub = parts[3] || '';

    if (!sub && req.method === 'GET') return json(res, 200, { code: room.code, ok: true });

    if (sub === 'join' && req.method === 'POST') {
      const body = await readJson(req);
      const s = game.join(room, body, now());
      changed(room);
      return json(res, 200, { token: s.token, studentId: s.id, name: s.name, group: s.group });
    }

    if (sub === 'flip' && req.method === 'POST') {
      const body = await readJson(req);
      const s = game.flip(room, body.token, now());
      changed(room);
      return json(res, 200, game.viewStudent(room, s, now()));
    }

    if (sub === 'teacher' && req.method === 'POST') {
      const body = await readJson(req);
      const { key, action, ...payload } = body;
      game.teacherAction(room, key, action, payload, now());
      changed(room);
      return json(res, 200, game.viewTeacher(room, now(), onlineSet(room.code)));
    }

    if (sub === 'state' && req.method === 'GET') {
      const as = url.searchParams.get('as');
      const cred = url.searchParams.get('key') || url.searchParams.get('token');
      return json(res, 200, viewFor(room, as, cred));
    }

    if (sub === 'events' && req.method === 'GET') {
      const as = url.searchParams.get('as');
      const cred = url.searchParams.get('key') || url.searchParams.get('token');
      const view = viewFor(room, as, cred); // 驗證失敗會丟出錯誤
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no',
      });
      res.write('retry: 1500\n\n');
      const entry = { res, as, cred, studentId: as === 'student' ? view.me.id : null, last: null };
      if (!subs.has(room.code)) subs.set(room.code, new Set());
      subs.get(room.code).add(entry);
      sendView(entry, view);
      const ping = setInterval(() => res.write(': ping\n\n'), 20000);
      if (entry.studentId) broadcastTeachers(room);
      req.on('close', () => {
        clearInterval(ping);
        subs.get(room.code)?.delete(entry);
        if (entry.studentId) broadcastTeachers(room);
      });
      return;
    }

    if (sub === 'qr.svg' && req.method === 'GET') {
      const svg = await QRCode.toString(`${baseUrl(req)}/j/${room.code}`, {
        type: 'svg',
        margin: 1,
        errorCorrectionLevel: 'M',
        color: { dark: '#0d2a30', light: '#ffffff' },
      });
      res.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'no-cache', ...SECURITY_HEADERS });
      return res.end(svg);
    }

    return notFound(res);
  }

  function broadcastTeachers(room) {
    const set = subs.get(room.code);
    if (!set) return;
    for (const sub of set) if (sub.as === 'teacher') {
      try {
        sendView(sub, viewFor(room, 'teacher', sub.cred));
      } catch {}
    }
  }

  function serveStatic(req, res, url) {
    let p = decodeURIComponent(url.pathname);
    const short = p.match(/^\/([jst])\/([A-Za-z0-9]{4,8})\/?$/);
    if (short) {
      const page = { j: 'join.html', s: 'screen.html', t: 'teacher.html' }[short[1]];
      res.writeHead(302, { Location: `/${page}?room=${short[2].toUpperCase()}` });
      return res.end();
    }
    if (p === '/') p = '/index.html';
    const file = path.normalize(path.join(PUBLIC_DIR, p));
    if (!file.startsWith(PUBLIC_DIR + path.sep)) return notFound(res);
    fs.stat(file, (err, st) => {
      if (err || !st.isFile()) return notFound(res);
      const ext = path.extname(file);
      res.writeHead(200, {
        'Content-Type': MIME[ext] || 'application/octet-stream',
        'Content-Length': st.size,
        'Cache-Control': ext === '.webp' ? 'public, max-age=604800' : 'no-cache',
        ...SECURITY_HEADERS,
      });
      if (req.method === 'HEAD') return res.end();
      fs.createReadStream(file).pipe(res);
    });
  }

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://local');
    try {
      if (url.pathname === '/healthz') return json(res, 200, { ok: true, rooms: store.rooms.size });
      if (url.pathname.startsWith('/api/')) return await handleApi(req, res, url);
      if (req.method !== 'GET' && req.method !== 'HEAD') return notFound(res);
      return serveStatic(req, res, url);
    } catch (err) {
      const status = err instanceof game.GameError ? err.status : err.status || 500;
      if (status >= 500) console.error(err);
      if (!res.headersSent) json(res, status, { error: status >= 500 ? '伺服器發生錯誤' : err.message });
      else res.end();
    }
  });

  const pruneTimer = setInterval(() => store.prune(now()), 60 * 60 * 1000);
  pruneTimer.unref();
  server.on('close', () => {
    clearInterval(pruneTimer);
    for (const { timer } of wakeTimers.values()) clearTimeout(timer);
    store.flush();
  });

  return { server, store, broadcast };
}

// ───────────── helpers ─────────────

function safeKey(a, b) {
  const crypto = require('node:crypto');
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length === y.length && x.length > 0 && crypto.timingSafeEqual(x, y);
}

function json(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...SECURITY_HEADERS,
  });
  res.end(body);
}
function notFound(res) {
  json(res, 404, { error: '找不到頁面' });
}
function sendEvent(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}
function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 16 * 1024) {
        reject(Object.assign(new game.GameError('資料太大'), { status: 413 }));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        const v = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        resolve(v && typeof v === 'object' ? v : {});
      } catch {
        reject(new game.GameError('資料格式錯誤'));
      }
    });
    req.on('error', reject);
  });
}

module.exports = { createApp };

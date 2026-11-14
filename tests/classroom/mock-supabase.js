// Test double for @supabase/supabase-js used only by the local e2e harness (injected in place of the CDN script).
// Implements the subset the site uses: anonymous auth with a configurable storage, rpc(), from('intel606_cards'),
// and channel().on('postgres_changes') emulated by polling the room version (stands in for Realtime).
(() => {
  const API = location.origin + '/api';
  async function post(path, data, uid) {
    const r = await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-user': uid || '' }, body: JSON.stringify(data || {}) });
    return r.json();
  }
  function createClient(url, key, opts = {}) {
    const auth = opts.auth || {};
    const storage = auth.storage || window.localStorage;
    const storageKey = auth.storageKey || ('sb-' + new URL(url).hostname.split('.')[0] + '-auth-token');
    const read = () => { try { return JSON.parse(storage.getItem(storageKey) || 'null'); } catch { return null; } };
    const client = {
      auth: {
        async getSession() { const s = read(); return { data: { session: s ? { user: s } : null }, error: null }; },
        async getUser() {
          const s = read();
          if (!s) return { data: { user: null }, error: { status: 401, message: 'session missing' } };
          const r = await fetch(API + '/user?id=' + s.id);
          return r.ok ? { data: { user: s }, error: null } : { data: { user: null }, error: { status: 404, message: 'User not found' } };
        },
        async signInAnonymously() { const u = await post('/anon'); storage.setItem(storageKey, JSON.stringify(u)); return { data: { user: u }, error: null }; },
        async signOut() { storage.removeItem(storageKey); return { error: null }; }
      },
      async rpc(name, args) {
        const s = read();
        const r = await post('/rpc/' + name, args, s && s.id);
        return r.error ? { data: null, error: r.error } : { data: r.data, error: null };
      },
      from(table) {
        const uid = () => (read() || {}).id;
        const q = { op: 'select' };
        const run = async () => { const r = await post('/cards', q, uid()); return r.error ? { data: null, error: r.error } : { data: r.data, error: null }; };
        const b = {
          select() { q.op = q.op || 'select'; return b; }, order() { return b; },
          insert(p) { q.op = 'insert'; q.payload = p; return b; }, update(p) { q.op = 'update'; q.payload = p; return b; },
          delete() { q.op = 'delete'; return b; }, eq(_c, v) { q.id = v; return b; },
          then(res, rej) { return run().then(res, rej); }
        };
        return b;
      },
      channel(name) {
        const ch = { handlers: [], timer: null, last: null,
          on(_type, filter, cb) { ch.handlers.push({ filter, cb }); return ch; },
          subscribe(cb) {
            const h = ch.handlers[0]; const id = h && /id=eq\.(.+)/.exec(h.filter.filter || '')?.[1];
            if (id) ch.timer = setInterval(async () => {
              try { const r = await (await fetch(API + '/version?id=' + id)).json();
                if (ch.last !== null && r.version !== ch.last) ch.handlers.forEach(x => x.cb({ new: { version: r.version } }));
                ch.last = r.version; } catch { /* ignore */ }
            }, 400);
            cb && cb('SUBSCRIBED'); return ch;
          } };
        return ch;
      },
      removeChannel(ch) { if (ch && ch.timer) clearInterval(ch.timer); }
    };
    return client;
  }
  window.supabase = { createClient };
})();

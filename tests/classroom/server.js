// Local test server: serves the site and a tiny Supabase-like API backed by local Postgres.
// Every RPC runs as role `authenticated` with request.jwt.claim.sub = the caller's anonymous user id,
// exactly the way PostgREST would execute the SECURITY DEFINER functions.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const ROOT = process.argv[2];
const DB = process.argv[3] || 'e2e';
const PORT = Number(process.argv[4] || 8606);
const pool = new Pool({ host: '/tmp', port: 5433, user: 'postgres', database: DB, max: 30 });
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.webp': 'image/webp', '.png': 'image/png', '.svg': 'image/svg+xml' };
let rpcCount = 0;

async function asUser(uid, sql, params) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query('set local role authenticated');
    await c.query("select set_config('request.jwt.claim.sub',$1,true)", [uid || '']);
    const r = await c.query(sql, params);
    await c.query('commit');
    return r;
  } catch (e) { await c.query('rollback').catch(() => {}); throw e; }
  finally { c.release(); }
}
function body(req) { return new Promise(res => { let b = ''; req.on('data', d => b += d); req.on('end', () => res(b ? JSON.parse(b) : {})); }); }
function send(res, code, obj) { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); }

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (url.pathname === '/api/anon') {
      const r = await pool.query('insert into auth.users default values returning id');
      return send(res, 200, { id: r.rows[0].id });
    }
    if (url.pathname === '/api/user') {
      const r = await pool.query('select id from auth.users where id=$1', [url.searchParams.get('id')]);
      return send(res, r.rows.length ? 200 : 404, r.rows[0] || { message: 'user not found' });
    }
    if (url.pathname === '/api/version') {
      const r = await pool.query('select version from public.intel606_rooms where id=$1', [url.searchParams.get('id')]);
      return send(res, 200, { version: r.rows[0]?.version ?? null });
    }
    if (url.pathname === '/api/stats') return send(res, 200, { rpcCount });
    if (url.pathname.startsWith('/api/rpc/')) {
      const fn = url.pathname.slice(9).replace(/[^a-z0-9_]/g, '');
      const args = await body(req);
      const keys = Object.keys(args);
      const sql = `select public.${fn}(${keys.map((k, i) => `${k.replace(/[^a-z_]/g, '')} => $${i + 1}`).join(',')}) as v`;
      rpcCount++;
      try {
        const r = await asUser(req.headers['x-user'], sql, keys.map(k => args[k]));
        return send(res, 200, { data: r.rows[0].v });
      } catch (e) { return send(res, 400, { error: { message: e.message } }); }
    }
    if (url.pathname === '/api/cards') {
      const args = await body(req);
      const uid = req.headers['x-user'];
      try {
        let r;
        if (args.op === 'select') r = await asUser(uid, 'select * from public.intel606_cards order by created_at desc', []);
        else if (args.op === 'insert') r = await asUser(uid, 'insert into public.intel606_cards(owner_id,board_size,category,title,active,cells) values($1,$2,$3,$4,$5,$6::jsonb) returning *', [args.payload.owner_id, args.payload.board_size, args.payload.category, args.payload.title, args.payload.active, JSON.stringify(args.payload.cells)]);
        else if (args.op === 'update') { const p = args.payload; const ks = Object.keys(p); r = await asUser(uid, `update public.intel606_cards set ${ks.map((k, i) => `${k.replace(/[^a-z_]/g, '')}=$${i + 1}${k === 'cells' ? '::jsonb' : ''}`).join(',')} where id=$${ks.length + 1}`, [...ks.map(k => k === 'cells' ? JSON.stringify(p[k]) : p[k]), args.id]); }
        else if (args.op === 'delete') r = await asUser(uid, 'delete from public.intel606_cards where id=$1', [args.id]);
        return send(res, 200, { data: r.rows || [] });
      } catch (e) { return send(res, 400, { error: { message: e.message } }); }
    }
    // static files
    let file = path.join(ROOT, decodeURIComponent(url.pathname));
    if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  } catch (e) { send(res, 500, { error: { message: e.message } }); }
}).listen(PORT, () => console.log('listening ' + PORT));

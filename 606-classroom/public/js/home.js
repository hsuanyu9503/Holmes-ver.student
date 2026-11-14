import { el, qs, api, crest } from './common.js';

qs('#crest').append(crest());
const err = qs('#err');
const pass = qs('#passcode');

function recentRooms() {
  const out = [];
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      const m = k && k.match(/^intel606c:t:([A-Z0-9]+)$/);
      if (m) out.push(m[1]);
    }
  } catch {}
  return out;
}

async function showRecent() {
  const codes = recentRooms();
  const list = qs('#recentList');
  for (const code of codes) {
    try {
      await api(`/api/rooms/${code}`);
      list.append(el('a', { class: 'btn-line', href: `/teacher.html?room=${code}`, style: { textAlign: 'center', textDecoration: 'none' } }, `繼續課堂 ${code}`));
    } catch {
      try { localStorage.removeItem(`intel606c:t:${code}`); } catch {}
    }
  }
  qs('#recent').hidden = !list.children.length;
}
showRecent();

qs('#create').addEventListener('click', async (e) => {
  err.textContent = '';
  e.target.disabled = true;
  try {
    const res = await api('/api/rooms', { passcode: pass.value });
    try { localStorage.setItem(`intel606c:t:${res.code}`, res.teacherKey); } catch {}
    location.href = `/teacher.html?room=${res.code}#k=${encodeURIComponent(res.teacherKey)}`;
  } catch (ex) {
    if (ex.status === 403) pass.hidden = false;
    err.textContent = ex.message;
    e.target.disabled = false;
  }
});

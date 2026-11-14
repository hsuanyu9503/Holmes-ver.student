import { el, qs, rpc, crest, configured, configMissing } from './common.js';

const err = qs('#err');
const pass = qs('#passcode');

if (!configured()) {
  configMissing(qs('#home'));
} else {
  qs('#crest').append(crest());
  init();
}

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

async function init() {
  rpc('c606_requires_passcode').then((need) => { pass.hidden = !need; }).catch(() => {});
  const list = qs('#recentList');
  for (const code of recentRooms()) {
    try {
      if (await rpc('c606_room_exists', { p_code: code })) {
        list.append(el('a', { class: 'btn-line', href: `teacher.html?room=${code}`, style: { textAlign: 'center', textDecoration: 'none' } }, `繼續課堂 ${code}`));
      } else {
        try { localStorage.removeItem(`intel606c:t:${code}`); } catch {}
      }
    } catch {}
  }
  qs('#recent').hidden = !list.children.length;
}

qs('#create').addEventListener('click', async (e) => {
  err.textContent = '';
  e.target.disabled = true;
  try {
    const res = await rpc('c606_create_room', { p_passcode: pass.value || null });
    try { localStorage.setItem(`intel606c:t:${res.code}`, res.teacherKey); } catch {}
    location.href = `teacher.html?room=${res.code}#k=${encodeURIComponent(res.teacherKey)}`;
  } catch (ex) {
    if (ex.status === 403) pass.hidden = false;
    err.textContent = ex.message;
    e.target.disabled = false;
  }
});

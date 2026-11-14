-- ═══════════════════════════════════════════════════════════════════════
-- 606 情報局｜近距課堂 — Supabase 資料庫（全新專案用，可重複執行）
--
-- 設計：
--   * 所有課堂資料放在 c606_private schema，anon／authenticated 完全無權直接讀寫。
--   * 前端只能呼叫 public.c606_* 函式（SECURITY DEFINER），函式內依身分過濾資料：
--       教師（teacher_key）、投影（只看公開資訊）、學生（個人 token）。
--   * public.c606_signals 只有「房間碼＋版本號」，透過 Supabase Realtime 通知各裝置重新讀取；
--     不含任何名單、身分或代碼。
--   * 身分分配與 18 格對照表從不離開資料庫；代碼在骰子動畫結束（reveal_at）後才放行。
--
-- 錯誤碼：PT401 學生憑證無效、PT403 教師金鑰／通行碼錯誤、PT404 找不到課堂、
--         PT409 階段或重複報到衝突、P0001 一般輸入錯誤。
-- ═══════════════════════════════════════════════════════════════════════

create schema if not exists c606_private;
revoke all on schema c606_private from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema c606_private from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema c606_private from authenticated'; end if;
end $$;

-- ───────────────────────── 資料表 ─────────────────────────

create table if not exists c606_private.settings (
  key text primary key,
  value text not null
);

create table if not exists c606_private.decks (
  id text primary key,
  title text not null,
  words text[] not null check (array_length(words, 1) = 9),
  sort int not null default 0
);

create table if not exists c606_private.rooms (
  code text primary key,
  teacher_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  round_no int not null default 1,
  phase text not null default 'lobby' check (phase in ('lobby','identity','dice','card','guess','ending')),
  selection jsonb not null default '{}'::jsonb,          -- {"1": studentId, …}
  deck_choice text not null default 'auto',
  custom_deck jsonb,                                       -- {title, words[9]}
  used_decks text[] not null default '{}',
  history jsonb not null default '[]'::jsonb
);

create table if not exists c606_private.students (
  id text primary key,
  room_code text not null references c606_private.rooms(code) on delete cascade,
  name text not null,
  grp int not null check (grp between 1 and 6),
  token text not null unique,
  variant text not null check (variant in ('m','f')),
  joined_at timestamptz not null default clock_timestamp(),
  ord bigint generated always as identity,
  reclaimable boolean not null default false
);
create index if not exists c606_students_room_idx on c606_private.students(room_code, grp);

create table if not exists c606_private.rounds (
  room_code text primary key references c606_private.rooms(code) on delete cascade,
  no int not null,
  started_at timestamptz not null default clock_timestamp(),
  players jsonb not null,                 -- {"1": studentId, … "6": studentId}
  spy_id text not null,
  code_map text[] not null,               -- 18 格：藍 1～6 列 × 紅 1～3 欄
  deck_id text not null,
  deck_title text not null,
  deck_words text[] not null,             -- A1 B1 C1 A2 B2 C2 A3 B3 C3
  blue int, red int,
  rolled_at timestamptz, reveal_at timestamptz,
  secret_code text,
  card_public boolean not null default false,
  step text,
  accused_group int,
  guess_code text,
  ending_type text,
  ending_at timestamptz
);

create table if not exists c606_private.round_roles (
  room_code text not null references c606_private.rooms(code) on delete cascade,
  student_id text not null references c606_private.students(id) on delete cascade,
  role text not null check (role in ('agent','spy','insider')),
  flipped_at timestamptz,
  primary key (room_code, student_id)
);

-- Realtime 通知表（公開，只有房間碼與版本號）
create table if not exists public.c606_signals (
  room_code text primary key,
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.c606_signals enable row level security;
drop policy if exists c606_signals_read on public.c606_signals;
create policy c606_signals_read on public.c606_signals for select using (true);
revoke all on public.c606_signals from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on public.c606_signals from anon; grant select on public.c606_signals to anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on public.c606_signals from authenticated; grant select on public.c606_signals to authenticated'; end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'c606_signals') then
    execute 'alter publication supabase_realtime add table public.c606_signals';
  end if;
end $$;

-- ───────────────────────── 內建情報卡主題 ─────────────────────────

insert into c606_private.decks(id, title, words, sort) values
  ('animals',    '動物偵探', array['企鵝','熊貓','海豹','北極熊','斑馬','海豚','鴕鳥','貓頭鷹','鯨魚'], 1),
  ('fruits',     '水果市集', array['西瓜','香蕉','鳳梨','芒果','草莓','葡萄','奇異果','荔枝','蘋果'], 2),
  ('vehicles',   '交通工具', array['腳踏車','公車','捷運','高鐵','飛機','輪船','機車','計程車','火箭'], 3),
  ('campus',     '校園角落', array['圖書館','操場','福利社','保健室','音樂教室','自然教室','禮堂','游泳池','校門口'], 4),
  ('sports',     '運動競技', array['籃球','足球','桌球','羽球','游泳','跳繩','棒球','排球','田徑'], 5),
  ('jobs',       '職業體驗', array['醫生','警察','消防員','老師','廚師','農夫','記者','工程師','太空人'], 6),
  ('nature',     '天氣自然', array['颱風','彩虹','閃電','地震','下雪','沙漠','火山','瀑布','森林'], 7),
  ('food',       '台灣小吃', array['珍珠奶茶','牛肉麵','小籠包','臭豆腐','滷肉飯','蚵仔煎','雞排','刈包','豆花'], 8),
  ('stationery', '文具用品', array['鉛筆','橡皮擦','直尺','剪刀','膠水','釘書機','立可帶','量角器','圓規'], 9),
  ('music',      '樂器演奏', array['鋼琴','小提琴','直笛','吉他','爵士鼓','口琴','長笛','小號','三角鐵'], 10)
on conflict (id) do nothing;

-- ───────────────────────── 工具函式 ─────────────────────────

-- 0 ≤ 結果 < n 的隨機整數（以 gen_random_uuid 的隨機位元為來源）
create or replace function c606_private.rand(n int) returns int
language sql volatile set search_path = '' as $$
  select (('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))::bit(48)::bigint % n)::int
$$;

create or replace function c606_private.new_token(parts int default 2) returns text
language sql volatile set search_path = '' as $$
  select string_agg(replace(gen_random_uuid()::text, '-', ''), '') from generate_series(1, parts)
$$;

create or replace function c606_private.cells() returns text[]
language sql immutable set search_path = '' as $$
  select array['A1','B1','C1','A2','B2','C2','A3','B3','C3']
$$;

create or replace function c606_private.ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as $$
  select (extract(epoch from t) * 1000)::bigint
$$;

create or replace function c606_private.fail(code text, msg text) returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = code, message = msg;
end $$;

-- 狀態變更：更新時間並遞增通知版本（觸發 Realtime）
create or replace function c606_private.touch(p_code text) returns void
language sql set search_path = '' as $$
  update c606_private.rooms set updated_at = clock_timestamp() where code = p_code;
  insert into public.c606_signals(room_code, version, updated_at) values (p_code, 1, now())
  on conflict (room_code) do update set version = public.c606_signals.version + 1, updated_at = now();
$$;

-- 清除閒置 24 小時的課堂
create or replace function c606_private.prune() returns void
language sql set search_path = '' as $$
  delete from public.c606_signals s using c606_private.rooms r
   where s.room_code = r.code and r.updated_at < clock_timestamp() - interval '24 hours';
  delete from c606_private.rooms where updated_at < clock_timestamp() - interval '24 hours';
$$;

create or replace function c606_private.load_room(p_code text, p_lock boolean default false)
returns c606_private.rooms language plpgsql set search_path = '' as $$
declare v c606_private.rooms;
begin
  if p_lock then
    select * into v from c606_private.rooms where code = upper(btrim(coalesce(p_code, ''))) for update;
  else
    select * into v from c606_private.rooms where code = upper(btrim(coalesce(p_code, '')));
  end if;
  if not found then perform c606_private.fail('PT404', '找不到這個課堂，請確認 QR Code 或房間碼'); end if;
  return v;
end $$;

-- ───────────────────────── 結局與回合重置 ─────────────────────────

create or replace function c606_private.ending_meta(t text) returns jsonb
language sql immutable set search_path = '' as $$
  select case t
    when 'spy_wrong'   then '{"title":"臥底勝利！","reason":"玩家指認錯人，臥底成功隱藏身分。","img":"end-spy","winner":"spy"}'
    when 'spy_tie'     then '{"title":"臥底勝利！","reason":"再次投票仍平手，臥底成功逃過指認。","img":"end-spy","winner":"spy"}'
    when 'spy_reverse' then '{"title":"臥底逆轉勝利！","reason":"臥底猜中機密詞語，成功逆轉。","img":"end-spy-reverse","winner":"spy"}'
    when 'agents'      then '{"title":"情報員勝利！","reason":"情報員成功揪出臥底，守住機密詞語。","img":"end-agents","winner":"agents"}'
  end::jsonb
$$;

create or replace function c606_private.end_round(p_code text, p_type text) returns void
language plpgsql set search_path = '' as $$
declare r c606_private.rounds;
begin
  update c606_private.rounds set ending_type = p_type, ending_at = clock_timestamp(), step = null
   where room_code = p_code returning * into r;
  update c606_private.rooms
     set phase = 'ending',
         history = history || jsonb_build_array(jsonb_build_object(
           'no', r.no, 'type', p_type, 'deck', r.deck_title, 'code', r.secret_code, 'at', c606_private.ms(clock_timestamp())))
   where code = p_code;
end $$;

create or replace function c606_private.reset_lobby(p_code text, p_advance boolean) returns void
language plpgsql set search_path = '' as $$
declare r c606_private.rounds; v_sel jsonb := '{}'::jsonb; g int;
begin
  select * into r from c606_private.rounds where room_code = p_code;
  if found then
    for g in 1..6 loop
      if exists (select 1 from c606_private.students s where s.id = r.players->>g::text and s.room_code = p_code) then
        v_sel := v_sel || jsonb_build_object(g::text, r.players->>g::text);
      end if;
    end loop;
    if p_advance then
      update c606_private.rooms set used_decks = used_decks || r.deck_id where code = p_code;
    end if;
  end if;
  delete from c606_private.round_roles where room_code = p_code;
  delete from c606_private.rounds where room_code = p_code;
  update c606_private.rooms
     set phase = 'lobby', selection = v_sel, round_no = round_no + (case when p_advance then 1 else 0 end)
   where code = p_code;
end $$;

-- ───────────────────────── 視圖（依身分過濾） ─────────────────────────

create or replace function c606_private.view_public(p_code text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  rm c606_private.rooms; r c606_private.rounds; v jsonb; spy c606_private.students;
  v_now timestamptz := clock_timestamp(); v_ver bigint; cells text[] := c606_private.cells();
begin
  select * into rm from c606_private.rooms where code = p_code;
  select * into r from c606_private.rounds where room_code = p_code;
  select version into v_ver from public.c606_signals where room_code = p_code;
  v := jsonb_build_object(
    'code', rm.code, 'roundNo', rm.round_no, 'phase', rm.phase,
    'serverNow', c606_private.ms(v_now), 'version', coalesce(v_ver, 0),
    'count', (select count(*) from c606_private.students where room_code = p_code),
    'board', null, 'step', r.step, 'accusedGroup', null, 'ending', null,
    'wakeAt', case when r.reveal_at is not null and v_now < r.reveal_at then c606_private.ms(r.reveal_at) end);
  if r.room_code is not null and r.card_public then
    v := v || jsonb_build_object('board', jsonb_build_object(
      'title', r.deck_title, 'words', to_jsonb(r.deck_words), 'cols', '["A","B","C"]'::jsonb, 'rows', '[1,2,3]'::jsonb));
  end if;
  if r.room_code is not null and rm.phase in ('guess','ending') then
    v := v || jsonb_build_object('accusedGroup', r.accused_group);
  end if;
  if r.ending_type is not null then
    select * into spy from c606_private.students where id = r.spy_id;
    v := v || jsonb_build_object('ending', c606_private.ending_meta(r.ending_type) || jsonb_build_object(
      'type', r.ending_type,
      'spy', case when spy.id is not null then jsonb_build_object('name', spy.name, 'group', spy.grp) end,
      'spyGroup', (select k::int from jsonb_each_text(r.players) as e(k, val) where val = r.spy_id),
      'secretCode', r.secret_code,
      'secretWord', r.deck_words[array_position(cells, r.secret_code)],
      'guessCode', r.guess_code,
      'guessWord', case when r.guess_code is not null then r.deck_words[array_position(cells, r.guess_code)] end));
  end if;
  return v;
end $$;

create or replace function c606_private.view_dice(p_code text) returns jsonb
language sql stable set search_path = '' as $$
  select case when r.rolled_at is null then null else jsonb_build_object(
    'blue', r.blue, 'red', r.red,
    'rolledAt', c606_private.ms(r.rolled_at), 'revealAt', c606_private.ms(r.reveal_at),
    'revealed', clock_timestamp() >= r.reveal_at) end
  from (select 1) x left join c606_private.rounds r on r.room_code = p_code
$$;

create or replace function c606_private.progress(p_code text) returns jsonb
language sql stable set search_path = '' as $$
  select case when not exists (select 1 from c606_private.rounds where room_code = p_code) then null else
    jsonb_build_object(
      'playersFlipped', count(*) filter (where role <> 'insider' and flipped_at is not null),
      'playersTotal',   count(*) filter (where role <> 'insider'),
      'insidersFlipped', count(*) filter (where role = 'insider' and flipped_at is not null),
      'insidersTotal',  count(*) filter (where role = 'insider')) end
  from c606_private.round_roles where room_code = p_code
$$;

create or replace function c606_private.view_teacher(p_code text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare rm c606_private.rooms; r c606_private.rounds;
begin
  select * into rm from c606_private.rooms where code = p_code;
  select * into r from c606_private.rounds where room_code = p_code;
  return c606_private.view_public(p_code) || jsonb_build_object(
    'as', 'teacher',
    'dice', c606_private.view_dice(p_code),
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'group', s.grp, 'online', false, 'reclaimable', s.reclaimable,
        'isPlayer', coalesce(rr.role <> 'insider', false),
        'flipped', rr.flipped_at is not null) order by s.ord)
      from c606_private.students s
      left join c606_private.round_roles rr on rr.room_code = p_code and rr.student_id = s.id
      where s.room_code = p_code), '[]'::jsonb),
    'selection', rm.selection,
    'players', case when r.room_code is not null then r.players end,
    'progress', c606_private.progress(p_code),
    'deckChoice', rm.deck_choice,
    'customDeck', rm.custom_deck,
    'decks', (select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'words', to_jsonb(d.words)) order by d.sort) from c606_private.decks d),
    'roundDeck', case when r.room_code is not null then jsonb_build_object('title', r.deck_title, 'words', to_jsonb(r.deck_words)) end,
    'history', (select coalesce(jsonb_agg(h order by i), '[]'::jsonb) from (
      select h, i from jsonb_array_elements(rm.history) with ordinality as t(h, i) order by i desc limit 10) x));
end $$;

create or replace function c606_private.view_student(p_code text, p_student text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  rm c606_private.rooms; r c606_private.rounds; s c606_private.students; rr c606_private.round_roles;
  v_card jsonb := null; v_revealed boolean;
begin
  select * into rm from c606_private.rooms where code = p_code;
  select * into s from c606_private.students where id = p_student;
  select * into r from c606_private.rounds where room_code = p_code;
  select * into rr from c606_private.round_roles where room_code = p_code and student_id = p_student;
  if rm.phase <> 'lobby' and rr.student_id is not null then
    v_revealed := r.reveal_at is not null and clock_timestamp() >= r.reveal_at;
    v_card := jsonb_build_object('flipped', rr.flipped_at is not null, 'role', null, 'variant', null,
                                 'intel', null, 'isPlayer', rr.role <> 'insider');
    if rr.flipped_at is not null then
      v_card := v_card || jsonb_build_object(
        'role', rr.role,
        'variant', case when rr.role = 'insider' then null else s.variant end,
        'intel', case when not v_revealed then null
                      when rr.role = 'spy' then jsonb_build_object('mission', '機密任務：觀察其他玩家的發言，推理本輪的機密情報。')
                      else jsonb_build_object('code', r.secret_code) end);
    end if;
  end if;
  return c606_private.view_public(p_code) || jsonb_build_object(
    'as', 'student',
    'me', jsonb_build_object('id', s.id, 'name', s.name, 'group', s.grp),
    'card', v_card);
end $$;

-- ───────────────────────── 公開 RPC ─────────────────────────

create or replace function public.c606_create_room(p_passcode text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_pass text; v_code text; v_key text; alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i int;
begin
  select value into v_pass from c606_private.settings where key = 'teacher_passcode';
  if coalesce(v_pass, '') <> '' and coalesce(p_passcode, '') <> v_pass then
    perform c606_private.fail('PT403', '教師通行碼錯誤');
  end if;
  perform c606_private.prune();
  loop
    v_code := '';
    for i in 1..6 loop v_code := v_code || substr(alphabet, c606_private.rand(length(alphabet)) + 1, 1); end loop;
    exit when not exists (select 1 from c606_private.rooms where code = v_code);
  end loop;
  v_key := c606_private.new_token(2);
  insert into c606_private.rooms(code, teacher_key) values (v_code, v_key);
  perform c606_private.touch(v_code);
  return jsonb_build_object('code', v_code, 'teacherKey', v_key);
end $$;

create or replace function public.c606_room_exists(p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from c606_private.rooms where code = upper(btrim(coalesce(p_code, ''))))
$$;

create or replace function public.c606_requires_passcode() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select value <> '' from c606_private.settings where key = 'teacher_passcode'), false)
$$;

create or replace function public.c606_join(p_code text, p_name text default null, p_group int default null, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare rm c606_private.rooms; s c606_private.students; v_name text;
begin
  rm := c606_private.load_room(p_code, true);
  if coalesce(p_token, '') <> '' then
    select * into s from c606_private.students where room_code = rm.code and token = p_token;
    if found then return jsonb_build_object('token', s.token, 'studentId', s.id, 'name', s.name, 'group', s.grp); end if;
  end if;
  v_name := btrim(regexp_replace(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]<>]', '', 'g'), '\s+', ' ', 'g'));
  if v_name = '' then perform c606_private.fail('P0001', '請輸入姓名'); end if;
  if char_length(v_name) > 12 then perform c606_private.fail('P0001', '姓名最多 12 個字'); end if;
  if p_group is null or p_group not between 1 and 6 then perform c606_private.fail('P0001', '請選擇第 1～6 組'); end if;

  select * into s from c606_private.students where room_code = rm.code and grp = p_group and lower(name) = lower(v_name);
  if found then
    if s.reclaimable then
      update c606_private.students set token = c606_private.new_token(2), reclaimable = false where id = s.id returning * into s;
      perform c606_private.touch(rm.code);
      return jsonb_build_object('token', s.token, 'studentId', s.id, 'name', s.name, 'group', s.grp);
    end if;
    perform c606_private.fail('PT409', format('「%s」已在第 %s 組報到。若是本人換了裝置，請老師在名單中按「允許重新登入」。', v_name, p_group));
  end if;
  if (select count(*) from c606_private.students where room_code = rm.code) >= 80 then
    perform c606_private.fail('P0001', '本課堂報到人數已滿');
  end if;

  insert into c606_private.students(id, room_code, name, grp, token, variant)
  values (substr(c606_private.new_token(1), 1, 12), rm.code, v_name, p_group, c606_private.new_token(2),
          case when c606_private.rand(2) = 1 then 'f' else 'm' end)
  returning * into s;
  -- 本輪進行中才報到的學生，直接擔任局內人
  if rm.phase <> 'lobby' then
    insert into c606_private.round_roles(room_code, student_id, role) values (rm.code, s.id, 'insider');
  end if;
  perform c606_private.touch(rm.code);
  return jsonb_build_object('token', s.token, 'studentId', s.id, 'name', s.name, 'group', s.grp);
end $$;

create or replace function public.c606_flip(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare rm c606_private.rooms; s c606_private.students;
begin
  rm := c606_private.load_room(p_code, true);
  select * into s from c606_private.students where room_code = rm.code and token = coalesce(p_token, '');
  if not found then perform c606_private.fail('PT401', '找不到報到資料，請重新掃碼'); end if;
  if rm.phase = 'lobby' or not exists (select 1 from c606_private.round_roles where room_code = rm.code and student_id = s.id) then
    perform c606_private.fail('PT409', '身分認證尚未開始');
  end if;
  update c606_private.round_roles set flipped_at = clock_timestamp()
   where room_code = rm.code and student_id = s.id and flipped_at is null;
  if found then perform c606_private.touch(rm.code); end if;
  return c606_private.view_student(rm.code, s.id);
end $$;

create or replace function public.c606_view(p_code text, p_as text, p_cred text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare rm c606_private.rooms; v_sid text;
begin
  rm := c606_private.load_room(p_code);
  if p_as = 'display' then
    return c606_private.view_public(rm.code) || jsonb_build_object('as', 'display', 'dice', c606_private.view_dice(rm.code));
  elsif p_as = 'teacher' then
    if coalesce(p_cred, '') = '' or p_cred <> rm.teacher_key then perform c606_private.fail('PT403', '教師金鑰錯誤'); end if;
    return c606_private.view_teacher(rm.code);
  elsif p_as = 'student' then
    select id into v_sid from c606_private.students where room_code = rm.code and token = coalesce(p_cred, '');
    if v_sid is null then perform c606_private.fail('PT401', '找不到報到資料，請重新掃碼'); end if;
    return c606_private.view_student(rm.code, v_sid);
  end if;
  perform c606_private.fail('P0001', '未知的畫面類型');
end $$;

create or replace function public.c606_teacher(p_code text, p_key text, p_action text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  rm c606_private.rooms; r c606_private.rounds; s c606_private.students; d c606_private.decks;
  p jsonb := coalesce(p_payload, '{}'::jsonb);
  g int; v_missing int[] := '{}'; v_spy_group int; v_codes text[]; v_tmp text; i int; j int;
  v_title text; v_words text[]; v_flipped int; v_blue int; v_red int; v_deck_id text;
begin
  rm := c606_private.load_room(p_code, true);
  if coalesce(p_key, '') = '' or p_key <> rm.teacher_key then perform c606_private.fail('PT403', '教師金鑰錯誤'); end if;
  select * into r from c606_private.rounds where room_code = rm.code;

  case p_action
  when 'select' then
    if rm.phase <> 'lobby' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    g := (p->>'group')::int;
    if g is null or g not between 1 and 6 then perform c606_private.fail('P0001', '請選擇第 1～6 組'); end if;
    if p->>'studentId' is null then
      update c606_private.rooms set selection = selection - g::text where code = rm.code;
    else
      select * into s from c606_private.students where id = p->>'studentId' and room_code = rm.code;
      if not found or s.grp <> g then perform c606_private.fail('P0001', format('這位學生不在第 %s 組', g)); end if;
      update c606_private.rooms set selection = selection || jsonb_build_object(g::text, s.id) where code = rm.code;
    end if;

  when 'deck' then
    if rm.phase <> 'lobby' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    if p->>'choice' = 'custom' then
      v_title := btrim(coalesce(p->'custom'->>'title', ''));
      if v_title = '' or char_length(v_title) > 8 then perform c606_private.fail('P0001', '自訂主題名稱需為 1～8 個字'); end if;
      select array_agg(btrim(w)) into v_words from jsonb_array_elements_text(coalesce(p->'custom'->'words', '[]'::jsonb)) as w;
      if coalesce(array_length(v_words, 1), 0) <> 9 or exists (select 1 from unnest(v_words) w where w = '' or char_length(w) > 6) then
        perform c606_private.fail('P0001', '請填滿九個詞語，每個最多 6 個字');
      end if;
      if (select count(distinct w) from unnest(v_words) w) <> 9 then perform c606_private.fail('P0001', '九個詞語不可重複'); end if;
      update c606_private.rooms set deck_choice = 'custom',
        custom_deck = jsonb_build_object('title', v_title, 'words', to_jsonb(v_words)) where code = rm.code;
    elsif p->>'choice' = 'auto' or exists (select 1 from c606_private.decks where id = p->>'choice') then
      update c606_private.rooms set deck_choice = p->>'choice' where code = rm.code;
    else
      perform c606_private.fail('P0001', '找不到這個情報卡主題');
    end if;

  when 'start' then
    if rm.phase <> 'lobby' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    for g in 1..6 loop
      if not exists (select 1 from c606_private.students st where st.id = rm.selection->>g::text and st.room_code = rm.code and st.grp = g) then
        v_missing := v_missing || g;
      end if;
    end loop;
    if array_length(v_missing, 1) > 0 then
      perform c606_private.fail('P0001', format('第 %s 組尚未選定玩家', array_to_string(v_missing, '、')));
    end if;
    -- 情報卡主題
    if rm.deck_choice = 'custom' and rm.custom_deck is not null then
      v_deck_id := 'custom'; v_title := rm.custom_deck->>'title';
      select array_agg(w order by n) into v_words from jsonb_array_elements_text(rm.custom_deck->'words') with ordinality as t(w, n);
    else
      select * into d from c606_private.decks where id = rm.deck_choice;
      if not found then
        select * into d from c606_private.decks where not (id = any(rm.used_decks)) order by random() limit 1;
        if not found then
          select * into d from c606_private.decks
           where id is distinct from rm.used_decks[array_length(rm.used_decks, 1)] order by random() limit 1;
        end if;
      end if;
      v_deck_id := d.id; v_title := d.title; v_words := d.words;
    end if;
    -- 18 格對照表：九個代碼各兩次，洗牌
    select array_agg(c) into v_codes from unnest(c606_private.cells()) as c cross join generate_series(1, 2);
    for i in reverse 18..2 loop
      j := c606_private.rand(i) + 1;
      v_tmp := v_codes[i]; v_codes[i] := v_codes[j]; v_codes[j] := v_tmp;
    end loop;
    v_spy_group := c606_private.rand(6) + 1;
    delete from c606_private.round_roles where room_code = rm.code;
    delete from c606_private.rounds where room_code = rm.code;
    insert into c606_private.rounds(room_code, no, players, spy_id, code_map, deck_id, deck_title, deck_words)
    values (rm.code, rm.round_no, rm.selection, rm.selection->>v_spy_group::text, v_codes, v_deck_id, v_title, v_words);
    insert into c606_private.round_roles(room_code, student_id, role)
    select rm.code, st.id,
           case when st.id = rm.selection->>v_spy_group::text then 'spy'
                when st.id in (select value from jsonb_each_text(rm.selection)) then 'agent'
                else 'insider' end
      from c606_private.students st where st.room_code = rm.code;
    update c606_private.rooms set phase = 'identity' where code = rm.code;

  when 'roll' then
    if rm.phase <> 'identity' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    select count(*) into v_flipped from c606_private.round_roles
     where room_code = rm.code and role <> 'insider' and flipped_at is not null;
    if v_flipped < 6 then perform c606_private.fail('P0001', format('還有 %s 名玩家尚未翻牌', 6 - v_flipped)); end if;
    v_blue := c606_private.rand(6) + 1;                         -- 藍：1～6
    v_red := (array[1,1,2,2,3,3])[c606_private.rand(6) + 1];     -- 紅：1、1、2、2、3、3
    update c606_private.rounds
       set blue = v_blue, red = v_red, rolled_at = clock_timestamp(),
           reveal_at = clock_timestamp() + interval '2600 milliseconds',
           secret_code = code_map[(v_blue - 1) * 3 + v_red]
     where room_code = rm.code;
    update c606_private.rooms set phase = 'dice' where code = rm.code;

  when 'publish' then
    if rm.phase <> 'dice' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    if clock_timestamp() < r.reveal_at then perform c606_private.fail('P0001', '骰子動畫尚未結束'); end if;
    update c606_private.rounds set card_public = true, step = 'speak' where room_code = rm.code;
    update c606_private.rooms set phase = 'card' where code = rm.code;

  when 'step' then
    if rm.phase <> 'card' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    if coalesce(p->>'step', '') not in ('speak', 'vote', 'revote') then perform c606_private.fail('P0001', '未知的步驟'); end if;
    update c606_private.rounds set step = p->>'step' where room_code = rm.code;

  when 'accuse' then
    if rm.phase <> 'card' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    g := (p->>'group')::int;
    if g is null or g not between 1 and 6 then perform c606_private.fail('P0001', '請選擇第 1～6 組'); end if;
    update c606_private.rounds set accused_group = g where room_code = rm.code;
    if r.players->>g::text = r.spy_id then
      update c606_private.rounds set step = 'guess' where room_code = rm.code;
      update c606_private.rooms set phase = 'guess' where code = rm.code;
    else
      perform c606_private.end_round(rm.code, 'spy_wrong');
    end if;

  when 'tie' then
    if rm.phase <> 'card' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    perform c606_private.end_round(rm.code, 'spy_tie');

  when 'guess' then
    if rm.phase <> 'guess' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    if not (coalesce(p->>'code', '') = any(c606_private.cells())) then perform c606_private.fail('P0001', '請選擇臥底猜的詞語'); end if;
    update c606_private.rounds set guess_code = p->>'code' where room_code = rm.code;
    perform c606_private.end_round(rm.code, case when p->>'code' = r.secret_code then 'spy_reverse' else 'agents' end);

  when 'next' then
    if rm.phase <> 'ending' then perform c606_private.fail('PT409', '目前階段無法執行這個操作'); end if;
    perform c606_private.reset_lobby(rm.code, true);

  when 'abort' then
    if rm.phase = 'lobby' then perform c606_private.fail('PT409', '目前沒有進行中的回合'); end if;
    perform c606_private.reset_lobby(rm.code, false);

  when 'remove' then
    select * into s from c606_private.students where id = p->>'studentId' and room_code = rm.code;
    if not found then perform c606_private.fail('P0001', '找不到這位學生'); end if;
    if rm.phase <> 'lobby' and exists (select 1 from c606_private.round_roles
         where room_code = rm.code and student_id = s.id and role <> 'insider') then
      perform c606_private.fail('P0001', '本輪玩家無法移除，請先結束本輪');
    end if;
    delete from c606_private.students where id = s.id;
    update c606_private.rooms
       set selection = (select coalesce(jsonb_object_agg(k, val), '{}'::jsonb) from jsonb_each_text(selection) as e(k, val) where val <> s.id)
     where code = rm.code;

  when 'unlock' then
    update c606_private.students set reclaimable = true where id = p->>'studentId' and room_code = rm.code;
    if not found then perform c606_private.fail('P0001', '找不到這位學生'); end if;

  else
    perform c606_private.fail('P0001', '未知的操作');
  end case;

  perform c606_private.touch(rm.code);
  return c606_private.view_teacher(rm.code);
end $$;

-- ───────────────────────── 權限 ─────────────────────────

revoke all on all tables in schema c606_private from public;
revoke all on all functions in schema c606_private from public;
do $$
declare fn text;
begin
  for fn in select unnest(array[
    'public.c606_create_room(text)', 'public.c606_room_exists(text)', 'public.c606_requires_passcode()',
    'public.c606_join(text, text, int, text)', 'public.c606_flip(text, text)',
    'public.c606_view(text, text, text)', 'public.c606_teacher(text, text, text, jsonb)'])
  loop
    execute format('revoke all on function %s from public', fn);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon', fn); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', fn); end if;
  end loop;
end $$;

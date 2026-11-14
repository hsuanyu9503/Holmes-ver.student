-- ==============================================================================
-- 606 情報局 v2.9.0 Classroom｜全新 Supabase 專案建置 SQL
-- = v2.8.0 Stable 全新建置 SQL（下方原文保留）＋ v2.8.0 → v2.9.0 近距課堂升級（檔尾）。
-- 【僅限全新專案】既有 v2.8.0 專案請改執行 606-v2.8.0-to-v2.9.0-classroom-upgrade.sql。
-- 建置前請啟用 Supabase Authentication 的 Anonymous Sign-ins。
-- ==============================================================================

-- ==============================================================================
-- 606 情報局 v2.8.0 Stable｜全新 Supabase 專案建置 SQL
-- 此檔整合 v2.7.0 Stable 的遊戲核心 + v2.8.0 遠距文字／語音獨立模式。
-- 【僅限全新專案】已部署 v2.8.0 Beta / Beta.1 / Beta.2 的專案不需執行 SQL。
-- 已部署 v2.7.0 / v2.7.1 者，請改用「2.7.1 -> 2.8.0 升級 SQL」。
-- 內含多筆歷史交易（BEGIN/COMMIT），請勿假設整份檔案一旦失敗會全回滾。
-- 保留歷史版本註解，以利日後追溯；可執行 SQL 完全沿用 Beta.2。
-- 建置前請啟用 Supabase Authentication 的 Anonymous Sign-ins。
-- ==============================================================================

-- ============================================================================
-- 606 情報局 v2.7.0 Stable｜正式版完整建置 SQL（唯一 SQL 入口）
-- 基準：已驗收的 v2.6.0 Stable＋v2.7.0 Beta／Beta.1／Beta.2／Beta.2.1
-- 已整合：雙面板、主控兼任玩家、自動主持、房間管理、情報卡抽取洗牌、
--         近距／遠距討論計時、身分保密與投票／猜測／結算。
-- 已包含 Beta.2.1 修補：intel606_room_state() 的 jsonb_build_object() 拆分。
--
-- 【只供全新 Supabase 專案使用】本檔是全新建置用，不是已部署專案的升級檔。
-- 已完成 Beta.2＋Beta.2.1 修補且正常運作的專案不需重跑本檔。
-- 需在 Authentication > Providers 啟用 Anonymous Sign-ins。
-- public schema 採明確 GRANT + RLS，私密資料維持在 intelligence_private。
-- 內部保留既有相容遷移與多次函式覆寫，保持已驗收的 SQL 執行順序。
-- 本檔包含三段歷史整合交易，若中間失敗，請勿假設先前已提交交易回滾；
-- 應檢查錯誤並於獨立測試專案重新驗證，而非直接重跑正式專案。
-- ============================================================================

begin;

create schema if not exists intelligence_private;
revoke all on schema intelligence_private from public, anon, authenticated;

create table if not exists public.intel606_cards (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  board_size integer not null check (board_size in (3,4)),
  category text not null check (char_length(btrim(category)) between 1 and 40),
  title text not null check (char_length(btrim(title)) between 1 and 80),
  cells jsonb not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint intel606_cells_shape check (
    case when jsonb_typeof(cells) = 'array'
      then jsonb_array_length(cells) = board_size * board_size and octet_length(cells::text) <= 8000
      else false end
  )
);
create index if not exists intel606_cards_owner_idx on public.intel606_cards(owner_id, board_size, active);

create table if not exists public.intel606_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique check (char_length(room_code) = 6),
  host_id uuid not null references auth.users(id) on delete cascade,
  board_size integer not null check (board_size in (3,4)),
  phase text not null default 'lobby' check (phase in ('lobby','identity','dossier','discussion','undercover','answer','closed')),
  round_no integer not null default 1 check (round_no > 0),
  current_card_id uuid references public.intel606_cards(id) on delete set null,
  current_card_snapshot jsonb,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  dice_rolled_at timestamptz
);
create index if not exists intel606_rooms_host_idx on public.intel606_rooms(host_id, updated_at desc);

-- 舊版房間表仍可能缺少 v2.5.5 起使用的擲骰開始時間欄位。
-- 新專案已有此欄位；IF NOT EXISTS 可安全重複執行。
alter table public.intel606_rooms
  add column if not exists dice_rolled_at timestamptz;


create table if not exists public.intel606_members (
  room_id uuid not null references public.intel606_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  seat_no integer not null check (seat_no between 1 and 8),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 24),
  is_ready boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, seat_no)
);

-- 防止正在進行中的舊局（尤其 v2.5.0 的碼表）被中途換成新規則。
-- 此守衛只檢查，不會清除或更新任何已儲存資料。
do $guard$
begin
  if exists (
    select 1 from public.intel606_rooms
    where phase not in ('lobby','closed')
  ) then
    raise exception '目前仍有進行中的 606 情報局房間。請先完成該輪並回到等待區或結束房間，再執行整合 SQL；此次變更已回滾。';
  end if;
end
$guard$;

-- v2.5.0 原有 rerolls 欄位會保留（已不再使用）；避免擅自刪除舊資料。
create table if not exists intelligence_private.intel606_secrets (
  room_id uuid primary key references public.intel606_rooms(id) on delete cascade,
  undercover_seat integer not null check (undercover_seat between 1 and 8),
  code_map jsonb not null,
  secret_code text,
  dice_first integer,
  dice_second integer
);

-- 不允許前端直接對房間、成員或機密資料進行寫入。
revoke all on public.intel606_rooms, public.intel606_members, public.intel606_cards from public, anon, authenticated;
revoke all on intelligence_private.intel606_secrets from public, anon, authenticated;
-- 明確 GRANT：避免 2026/10/30 後新表無法使用 Data API。
grant select on public.intel606_rooms to authenticated;
grant select, insert, update, delete on public.intel606_cards to authenticated;

alter table public.intel606_rooms enable row level security;
alter table public.intel606_members enable row level security;
alter table public.intel606_cards enable row level security;
alter table intelligence_private.intel606_secrets enable row level security;

-- 將既有版本的同名 Policy 原子化重建，避免重跑時 duplicate_object。
-- DROP POLICY 不影響情報卡或房間紀錄；整個動作包在單一交易中。
drop policy if exists intel606_card_select on public.intel606_cards;
drop policy if exists intel606_card_insert on public.intel606_cards;
drop policy if exists intel606_card_update on public.intel606_cards;
drop policy if exists intel606_card_delete on public.intel606_cards;
drop policy if exists intel606_room_select on public.intel606_rooms;

-- 情報卡只開放本人管理；其他人只能透過受檢查的 RPC 取得當輪公開題卡。
create policy intel606_card_select on public.intel606_cards for select to authenticated using (owner_id = (select auth.uid()));
create policy intel606_card_insert on public.intel606_cards for insert to authenticated with check (owner_id = (select auth.uid()));
create policy intel606_card_update on public.intel606_cards for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy intel606_card_delete on public.intel606_cards for delete to authenticated using (owner_id = (select auth.uid()));

-- 防止非房間成員透過 REST 或 Realtime 讀取房間列。
create or replace function public.intel606_can_read_room(p_room uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.intel606_rooms r where r.id = p_room and r.host_id = auth.uid())
      or exists (select 1 from public.intel606_members m where m.room_id = p_room and m.user_id = auth.uid());
$$;
revoke all on function public.intel606_can_read_room(uuid) from public, anon, authenticated;
grant execute on function public.intel606_can_read_room(uuid) to authenticated;
create policy intel606_room_select on public.intel606_rooms for select to authenticated
  using (public.intel606_can_read_room(id));

-- 使用核心 UUID 隨機來源，每次抽 0..n-1，丟棄不能公平整除的尾段值。
create or replace function intelligence_private.intel606_rand(p_n integer)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare v integer; v_max integer;
begin
  if p_n < 1 or p_n > 256 then raise exception 'invalid random range'; end if;
  v_max := 256 - (256 % p_n);
  loop
    v := get_byte(decode(substr(replace(gen_random_uuid()::text, '-', ''), 1, 2), 'hex'), 0);
    if v < v_max then return v % p_n; end if;
  end loop;
end;
$$;
revoke all on function intelligence_private.intel606_rand(integer) from public, anon, authenticated;

-- 所有敏感欄位只會經過此函式，依照呼叫者與遊戲階段分流。
create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') then v_unmasked := v_secret.undercover_seat; end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

create or replace function public.intel606_create_room(p_size integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room uuid; v_code text; v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; v_i integer; v_tries integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if p_size not in (3,4) then raise exception '只支援 3×3 與 4×4'; end if;
  for v_tries in 1..10 loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, intelligence_private.intel606_rand(length(v_alphabet)) + 1, 1);
    end loop;
    begin
      insert into public.intel606_rooms(room_code,host_id,board_size) values(v_code,auth.uid(),p_size) returning id into v_room;
      return public.intel606_room_state(v_room);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception '無法分配房間代碼，請再試一次';
end;
$$;

create or replace function public.intel606_join_room(p_code text, p_name text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype; v_number integer; v_used integer[];
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if char_length(btrim(coalesce(p_name,''))) not between 1 and 24 then raise exception '暱稱需為 1～24 字'; end if;
  select * into v_room from public.intel606_rooms where room_code = upper(btrim(p_code)) for update;
  if not found then raise exception '查無此房間，請檢查代碼'; end if;
  if v_room.host_id = auth.uid() then raise exception '主控裝置不能以玩家身分加入自己的房間'; end if;
  if exists(select 1 from public.intel606_members where room_id=v_room.id and user_id=auth.uid()) then
    return public.intel606_room_state(v_room.id);
  end if;
  if v_room.phase <> 'lobby' then raise exception '遊戲已開始，暫時無法加入'; end if;
  select coalesce(array_agg(seat_no), '{}'::integer[]) into v_used from public.intel606_members where room_id=v_room.id;
  select g.seat into v_number from generate_series(1,8) as g(seat)
    where not (g.seat = any(v_used)) order by g.seat limit 1;
  if v_number is null then raise exception '房間已滿（最多 8 位）'; end if;
  insert into public.intel606_members(room_id,user_id,seat_no,display_name)
    values(v_room.id,auth.uid(),v_number,btrim(p_name));
  update public.intel606_rooms set version=version+1,updated_at=now() where id=v_room.id;
  return public.intel606_room_state(v_room.id);
end;
$$;

create or replace function public.intel606_ready(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_phase text;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select phase into v_phase from public.intel606_rooms where id=p_room for update;
  if not found or v_phase <> 'identity' then raise exception '目前不能確認身分'; end if;
  update public.intel606_members set is_ready=true where room_id=p_room and user_id=auth.uid();
  if not found then raise exception '只有本房間玩家可確認'; end if;
  update public.intel606_rooms set version=version+1, updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 主控端唯一可以推進的階段。所有抽籤結果都在資料庫建立，不信任前端傳入答案。
create or replace function public.intel606_host_action(p_room uuid, p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_total integer; v_ready integer;
  v_codes text[] := '{}'::text[]; v_temp text; v_j integer; v_i integer; v_repeat integer;
  v_spy integer; v_first integer; v_second integer; v_offset integer;
  v_secret text; v_card uuid; v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可以執行此操作'; end if;
  select count(*),count(*) filter (where is_ready) into v_total,v_ready from public.intel606_members where room_id=p_room;
  if p_action = 'start' and v_room.phase = 'lobby' then
    if v_total < 3 or v_total > 8 then raise exception '需有 3～8 位玩家才能開始'; end if;
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    -- 3×3：九組代號各兩次，共18位置（6×3）。
    -- 4×4：十六組代號各三次，共48位置（8×6）。
    for v_i in 0..(v_room.board_size*v_room.board_size-1) loop
      for v_repeat in 1..(case when v_room.board_size = 3 then 2 else 3 end) loop
        v_codes := array_append(v_codes,
          substr('ABCD', (v_i % v_room.board_size)+1, 1) || ((v_i/v_room.board_size)+1)::text);
      end loop;
    end loop;
    for v_i in reverse array_length(v_codes,1)..2 loop
      v_j := intelligence_private.intel606_rand(v_i) + 1;
      v_temp := v_codes[v_i]; v_codes[v_i] := v_codes[v_j]; v_codes[v_j] := v_temp;
    end loop;
    v_spy := intelligence_private.intel606_rand(v_total) + 1;
    -- 下一輪如果編號不連續，不直接假設有 1..N，從實際成員隨機選。
    select seat_no into v_spy from public.intel606_members where room_id=p_room order by seat_no offset (v_spy-1) limit 1;
    insert into intelligence_private.intel606_secrets(room_id,undercover_seat,code_map)
      values(p_room,v_spy,to_jsonb(v_codes));
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='identity',current_card_id=null,current_card_snapshot=null,dice_rolled_at=null where id=p_room;
  elsif p_action = 'roll' and v_room.phase = 'identity' then
    if v_ready <> v_total then raise exception '請等所有玩家確認身分卡後再擲骰'; end if;
    if v_room.board_size = 3 then
      v_first := intelligence_private.intel606_rand(6) + 1;  -- 藍：1～6
      v_second := intelligence_private.intel606_rand(3) + 1; -- 紅：1/1/2/2/3/3
      v_offset := (v_first - 1) * 3 + (v_second - 1);
    else
      v_first := intelligence_private.intel606_rand(8) + 1;  -- 藍：1～8
      v_second := intelligence_private.intel606_rand(6) + 1; -- 紅：1～6，永不重擲
      v_offset := (v_first - 1) * 6 + (v_second - 1);
    end if;
    -- 以雙色骰子定位對照表的唯一位置，再由該位置讀取機密代號。
    select code_map->>v_offset into v_secret
      from intelligence_private.intel606_secrets where room_id=p_room;
    if v_secret is null then raise exception '代號對照表資料不完整，請建立新一輪任務'; end if;
    update intelligence_private.intel606_secrets
       set secret_code=v_secret,dice_first=v_first,dice_second=v_second
      where room_id=p_room;
    update public.intel606_rooms set phase='dossier',dice_rolled_at=clock_timestamp() where id=p_room;
  elsif p_action = 'draw' and v_room.phase = 'dossier' then
    select id into v_card from public.intel606_cards
       where owner_id=auth.uid() and board_size=v_room.board_size and active=true order by random() limit 1;
    if v_card is null then raise exception '沒有符合此宮格的啟用情報卡，請先建立'; end if;
    select jsonb_build_object('id',id,'title',title,'category',category,'cells',cells)
      into v_snapshot from public.intel606_cards where id=v_card;
    update public.intel606_rooms set phase='discussion',current_card_id=v_card,current_card_snapshot=v_snapshot where id=p_room;
  elsif p_action = 'unmask' and v_room.phase = 'discussion' then
    update public.intel606_rooms set phase='undercover' where id=p_room;
  elsif p_action = 'answer' and v_room.phase = 'undercover' then
    update public.intel606_rooms set phase='answer' where id=p_room;
  elsif p_action = 'next' and v_room.phase = 'answer' then
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='lobby',round_no=round_no+1,current_card_id=null,current_card_snapshot=null,dice_rolled_at=null where id=p_room;
  elsif p_action = 'close' and v_room.phase <> 'closed' then
    update public.intel606_rooms set phase='closed' where id=p_room;
  else
    raise exception '目前階段不允許執行這個操作';
  end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;


-- 教師端的房間管理：只能在等待玩家階段移除座位。
create or replace function public.intel606_remove_member(p_room uuid, p_seat integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可以管理房間玩家'; end if;
  if v_room.phase <> 'lobby' then raise exception '只有等待玩家階段可移除玩家'; end if;
  if p_seat not between 1 and 8 then raise exception '無效的座位編號'; end if;
  delete from public.intel606_members where room_id=p_room and seat_no=p_seat;
  if not found then raise exception '找不到此玩家'; end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;
revoke all on function public.intel606_remove_member(uuid,integer) from public, anon, authenticated;
grant execute on function public.intel606_remove_member(uuid,integer) to authenticated;

-- RPC 函式除了 authenticated 外都不可呼叫（明確 GRANT）。
revoke all on function public.intel606_room_state(uuid) from public, anon, authenticated;
revoke all on function public.intel606_create_room(integer) from public, anon, authenticated;
revoke all on function public.intel606_join_room(text,text) from public, anon, authenticated;
revoke all on function public.intel606_ready(uuid) from public, anon, authenticated;
revoke all on function public.intel606_host_action(uuid,text) from public, anon, authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
grant execute on function public.intel606_create_room(integer) to authenticated;
grant execute on function public.intel606_join_room(text,text) to authenticated;
grant execute on function public.intel606_ready(uuid) to authenticated;
grant execute on function public.intel606_host_action(uuid,text) to authenticated;

-- 僅公開「房間進度」變動，絕不把私密身分／秘密代碼放進 Realtime publication。
do $$
begin
  if exists(select 1 from pg_publication where pubname = 'supabase_realtime') and
     not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='intel606_rooms') then
    alter publication supabase_realtime add table public.intel606_rooms;
  end if;
end $$;



-- =======================================================================
-- 606 情報局 v2.6.0 R1｜近距／遠距分流與房間討論設定
-- 來源：v2.5.7 Unified Baseline
-- 對象：既有 v2.5.7 統一資料庫（先完成／關閉正在進行的回合）
-- 保護：保留情報卡、既有房間、玩家、骰子、秘密資料與原本 RPC。
-- 注意：本階段遠距僅到「輪流發言準備（clue）」；R2 才開放文字提交。
-- 新專案可使用 606-intelligence-v2.6.0-R1-full.sql（勿重複執行兩份）。
-- =======================================================================

-- 不在遊戲中途更換版號與狀態規則。等待區的既有房間維持近距模式。
do $guard$
begin
  if exists (select 1 from public.intel606_rooms where phase not in ('lobby','closed')) then
    raise exception '仍有正在進行的 606 情報局房間。請完成該輪並返回等待區或結束房間，然後重新執行 R1 升級 SQL；本次變更已回滾。';
  end if;
end
$guard$;

alter table public.intel606_rooms
  add column if not exists play_mode text not null default 'near',
  add column if not exists discussion_mode text not null default 'manual',
  add column if not exists discussion_seconds integer not null default 300;

-- CHECK 約束可重跑，不會清除既有資料。
alter table public.intel606_rooms drop constraint if exists intel606_rooms_play_mode_check;
alter table public.intel606_rooms add constraint intel606_rooms_play_mode_check
  check (play_mode in ('near','remote'));
alter table public.intel606_rooms drop constraint if exists intel606_rooms_discussion_mode_check;
alter table public.intel606_rooms add constraint intel606_rooms_discussion_mode_check
  check (discussion_mode in ('manual','timed'));
alter table public.intel606_rooms drop constraint if exists intel606_rooms_discussion_seconds_check;
alter table public.intel606_rooms add constraint intel606_rooms_discussion_seconds_check
  check (discussion_seconds in (180,300,480,600));

-- 近距原有 discussion 階段原封不動，遠距額外保留 clue 作為 R2 的入口。
alter table public.intel606_rooms drop constraint if exists intel606_rooms_phase_check;
alter table public.intel606_rooms add constraint intel606_rooms_phase_check
  check (phase in ('lobby','identity','dossier','clue','discussion','undercover','answer','closed'));

-- 不覆寫既有建立房間 RPC 的參數規格，避免 v2.5.7 舊前端失效。
-- 新版採用獨立且名稱清楚的 RPC，避免 PostgREST overloaded function 歧義。
create or replace function public.intel606_create_room_v26(
  p_size integer, p_play_mode text, p_discussion_mode text, p_discussion_seconds integer
)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room uuid; v_code text; v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_i integer; v_tries integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if p_size is null or p_size not in (3,4) then raise exception '只支援 3×3 與 4×4'; end if;
  if p_play_mode is null or p_play_mode not in ('near','remote') then raise exception '無效的遊戲模式'; end if;
  if p_discussion_mode is null or p_discussion_mode not in ('manual','timed') then raise exception '無效的討論方式'; end if;
  if p_discussion_seconds is null or p_discussion_seconds not in (180,300,480,600) then
    raise exception '討論時間只能設定 3、5、8 或 10 分鐘';
  end if;
  -- 近距遊戲不啟用遠距討論機制；正規化設定避免無效組合。
  if p_play_mode = 'near' then
    p_discussion_mode := 'manual';
    p_discussion_seconds := 300;
  end if;
  for v_tries in 1..10 loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, intelligence_private.intel606_rand(length(v_alphabet)) + 1, 1);
    end loop;
    begin
      insert into public.intel606_rooms(room_code,host_id,board_size,play_mode,discussion_mode,discussion_seconds)
        values(v_code,auth.uid(),p_size,p_play_mode,p_discussion_mode,p_discussion_seconds)
        returning id into v_room;
      return public.intel606_room_state(v_room);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception '無法分配房間代碼，請再試一次';
end;
$$;

create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') then v_unmasked := v_secret.undercover_seat; end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'discussion_seconds', v_room.discussion_seconds,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

create or replace function public.intel606_host_action(p_room uuid, p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_total integer; v_ready integer;
  v_codes text[] := '{}'::text[]; v_temp text; v_j integer; v_i integer; v_repeat integer;
  v_spy integer; v_first integer; v_second integer; v_offset integer;
  v_secret text; v_card uuid; v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可以執行此操作'; end if;
  select count(*),count(*) filter (where is_ready) into v_total,v_ready from public.intel606_members where room_id=p_room;
  if p_action = 'start' and v_room.phase = 'lobby' then
    if v_total < 3 or v_total > 8 then raise exception '需有 3～8 位玩家才能開始'; end if;
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    -- 3×3：九組代號各兩次，共18位置（6×3）。
    -- 4×4：十六組代號各三次，共48位置（8×6）。
    for v_i in 0..(v_room.board_size*v_room.board_size-1) loop
      for v_repeat in 1..(case when v_room.board_size = 3 then 2 else 3 end) loop
        v_codes := array_append(v_codes,
          substr('ABCD', (v_i % v_room.board_size)+1, 1) || ((v_i/v_room.board_size)+1)::text);
      end loop;
    end loop;
    for v_i in reverse array_length(v_codes,1)..2 loop
      v_j := intelligence_private.intel606_rand(v_i) + 1;
      v_temp := v_codes[v_i]; v_codes[v_i] := v_codes[v_j]; v_codes[v_j] := v_temp;
    end loop;
    v_spy := intelligence_private.intel606_rand(v_total) + 1;
    -- 下一輪如果編號不連續，不直接假設有 1..N，從實際成員隨機選。
    select seat_no into v_spy from public.intel606_members where room_id=p_room order by seat_no offset (v_spy-1) limit 1;
    insert into intelligence_private.intel606_secrets(room_id,undercover_seat,code_map)
      values(p_room,v_spy,to_jsonb(v_codes));
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='identity',current_card_id=null,current_card_snapshot=null,dice_rolled_at=null where id=p_room;
  elsif p_action = 'roll' and v_room.phase = 'identity' then
    if v_ready <> v_total then raise exception '請等所有玩家確認身分卡後再擲骰'; end if;
    if v_room.board_size = 3 then
      v_first := intelligence_private.intel606_rand(6) + 1;  -- 藍：1～6
      v_second := intelligence_private.intel606_rand(3) + 1; -- 紅：1/1/2/2/3/3
      v_offset := (v_first - 1) * 3 + (v_second - 1);
    else
      v_first := intelligence_private.intel606_rand(8) + 1;  -- 藍：1～8
      v_second := intelligence_private.intel606_rand(6) + 1; -- 紅：1～6，永不重擲
      v_offset := (v_first - 1) * 6 + (v_second - 1);
    end if;
    -- 以雙色骰子定位對照表的唯一位置，再由該位置讀取機密代號。
    select code_map->>v_offset into v_secret
      from intelligence_private.intel606_secrets where room_id=p_room;
    if v_secret is null then raise exception '代號對照表資料不完整，請建立新一輪任務'; end if;
    update intelligence_private.intel606_secrets
       set secret_code=v_secret,dice_first=v_first,dice_second=v_second
      where room_id=p_room;
    update public.intel606_rooms set phase='dossier',dice_rolled_at=clock_timestamp() where id=p_room;
  elsif p_action = 'draw' and v_room.phase = 'dossier' then
    select id into v_card from public.intel606_cards
       where owner_id=auth.uid() and board_size=v_room.board_size and active=true order by random() limit 1;
    if v_card is null then raise exception '沒有符合此宮格的啟用情報卡，請先建立'; end if;
    select jsonb_build_object('id',id,'title',title,'category',category,'cells',cells)
      into v_snapshot from public.intel606_cards where id=v_card;
    update public.intel606_rooms
       set phase = case when v_room.play_mode = 'remote' then 'clue' else 'discussion' end,
           current_card_id=v_card,current_card_snapshot=v_snapshot where id=p_room;
  elsif p_action = 'unmask' and v_room.phase = 'discussion' then
    update public.intel606_rooms set phase='undercover' where id=p_room;
  elsif p_action = 'answer' and v_room.phase = 'undercover' then
    update public.intel606_rooms set phase='answer' where id=p_room;
  elsif p_action = 'next' and v_room.phase = 'answer' then
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='lobby',round_no=round_no+1,current_card_id=null,current_card_snapshot=null,dice_rolled_at=null where id=p_room;
  elsif p_action = 'close' and v_room.phase <> 'closed' then
    update public.intel606_rooms set phase='closed' where id=p_room;
  else
    raise exception '目前階段不允許執行這個操作';
  end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 依 2026/10/30 新 Data API 行為明確授權；不依賴預設開放。
-- 新欄位已納入既有 SELECT 的 RLS 房間成員限制。
revoke all on function public.intel606_create_room_v26(integer,text,text,integer) from public, anon, authenticated;
grant execute on function public.intel606_create_room_v26(integer,text,text,integer) to authenticated;
revoke all on function public.intel606_room_state(uuid) from public, anon, authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
revoke all on function public.intel606_host_action(uuid,text) from public, anon, authenticated;
grant execute on function public.intel606_host_action(uuid,text) to authenticated;
grant select on public.intel606_rooms to authenticated;

-- 促使 PostgREST 更新新建 RPC 的 schema cache。
notify pgrst, 'reload schema';

-- === R2 遠距線索擴充：與前段在同一交易 ===
do $guard$
begin
  if exists(select 1 from public.intel606_rooms where phase not in ('lobby','closed')) then
    raise exception 'R2 升級中止：仍有進行中的房間，請先結束或返回等待區。本次未變更資料。';
  end if;
end
$guard$;

alter table public.intel606_rooms
  add column if not exists clue_current_seat integer,
  add column if not exists clue_completed_at timestamptz;
-- 不讓當輪完成後仍殘留輪到誰。
alter table public.intel606_rooms drop constraint if exists intel606_rooms_clue_seat_check;
alter table public.intel606_rooms add constraint intel606_rooms_clue_seat_check
  check (clue_current_seat is null or clue_current_seat between 1 and 8);

-- 線索放在非公開 schema，僅由受權限檢查的 RPC 讀寫。
create table if not exists intelligence_private.intel606_clues (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.intel606_rooms(id) on delete cascade,
  round_no integer not null check(round_no>0),
  seat_no integer not null check (seat_no between 1 and 8),
  clue_text text,
  was_skipped boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  constraint intel606_clue_valid check (
    (was_skipped and clue_text is null) or
    (not was_skipped and clue_text is not null and char_length(btrim(clue_text)) between 1 and 80)
  ),
  unique(room_id,round_no,seat_no)
);
create index if not exists intel606_clues_room_round_idx
  on intelligence_private.intel606_clues(room_id,round_no,seat_no);
revoke all on intelligence_private.intel606_clues from public,anon,authenticated;
alter table intelligence_private.intel606_clues enable row level security;
-- private schema 不對客戶端開放；不建立可供玩家直接 SELECT 的 policy。

create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') then v_unmasked := v_secret.undercover_seat; end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase = 'clue' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', c.clue_text, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'discussion_seconds', v_room.discussion_seconds,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase = 'clue' then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase = 'clue' and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

create or replace function public.intel606_host_action(p_room uuid, p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_total integer; v_ready integer;
  v_codes text[] := '{}'::text[]; v_temp text; v_j integer; v_i integer; v_repeat integer;
  v_spy integer; v_first integer; v_second integer; v_offset integer;
  v_secret text; v_card uuid; v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可以執行此操作'; end if;
  select count(*),count(*) filter (where is_ready) into v_total,v_ready from public.intel606_members where room_id=p_room;
  if p_action = 'start' and v_room.phase = 'lobby' then
    if v_total < 3 or v_total > 8 then raise exception '需有 3～8 位玩家才能開始'; end if;
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    -- 3×3：九組代號各兩次，共18位置（6×3）。
    -- 4×4：十六組代號各三次，共48位置（8×6）。
    for v_i in 0..(v_room.board_size*v_room.board_size-1) loop
      for v_repeat in 1..(case when v_room.board_size = 3 then 2 else 3 end) loop
        v_codes := array_append(v_codes,
          substr('ABCD', (v_i % v_room.board_size)+1, 1) || ((v_i/v_room.board_size)+1)::text);
      end loop;
    end loop;
    for v_i in reverse array_length(v_codes,1)..2 loop
      v_j := intelligence_private.intel606_rand(v_i) + 1;
      v_temp := v_codes[v_i]; v_codes[v_i] := v_codes[v_j]; v_codes[v_j] := v_temp;
    end loop;
    v_spy := intelligence_private.intel606_rand(v_total) + 1;
    -- 下一輪如果編號不連續，不直接假設有 1..N，從實際成員隨機選。
    select seat_no into v_spy from public.intel606_members where room_id=p_room order by seat_no offset (v_spy-1) limit 1;
    insert into intelligence_private.intel606_secrets(room_id,undercover_seat,code_map)
      values(p_room,v_spy,to_jsonb(v_codes));
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='identity',current_card_id=null,current_card_snapshot=null,dice_rolled_at=null,clue_current_seat=null,clue_completed_at=null where id=p_room;
  elsif p_action = 'roll' and v_room.phase = 'identity' then
    if v_ready <> v_total then raise exception '請等所有玩家確認身分卡後再擲骰'; end if;
    if v_room.board_size = 3 then
      v_first := intelligence_private.intel606_rand(6) + 1;  -- 藍：1～6
      v_second := intelligence_private.intel606_rand(3) + 1; -- 紅：1/1/2/2/3/3
      v_offset := (v_first - 1) * 3 + (v_second - 1);
    else
      v_first := intelligence_private.intel606_rand(8) + 1;  -- 藍：1～8
      v_second := intelligence_private.intel606_rand(6) + 1; -- 紅：1～6，永不重擲
      v_offset := (v_first - 1) * 6 + (v_second - 1);
    end if;
    -- 以雙色骰子定位對照表的唯一位置，再由該位置讀取機密代號。
    select code_map->>v_offset into v_secret
      from intelligence_private.intel606_secrets where room_id=p_room;
    if v_secret is null then raise exception '代號對照表資料不完整，請建立新一輪任務'; end if;
    update intelligence_private.intel606_secrets
       set secret_code=v_secret,dice_first=v_first,dice_second=v_second
      where room_id=p_room;
    update public.intel606_rooms set phase='dossier',dice_rolled_at=clock_timestamp() where id=p_room;
  elsif p_action = 'draw' and v_room.phase = 'dossier' then
    select id into v_card from public.intel606_cards
       where owner_id=auth.uid() and board_size=v_room.board_size and active=true order by random() limit 1;
    if v_card is null then raise exception '沒有符合此宮格的啟用情報卡，請先建立'; end if;
    select jsonb_build_object('id',id,'title',title,'category',category,'cells',cells)
      into v_snapshot from public.intel606_cards where id=v_card;
    update public.intel606_rooms
       set phase = case when v_room.play_mode = 'remote' then 'clue' else 'discussion' end,
           current_card_id=v_card,current_card_snapshot=v_snapshot,
           clue_current_seat = case when v_room.play_mode='remote' then
             (select min(m.seat_no) from public.intel606_members m where m.room_id=p_room) else null end,
           clue_completed_at = null
      where id=p_room;
  elsif p_action = 'skip_clue' and v_room.play_mode = 'remote' and v_room.phase = 'clue' then
    if v_room.clue_current_seat is null or v_room.clue_completed_at is not null then
      raise exception '所有線索已完成，不能再跳過發言';
    end if;
    insert into intelligence_private.intel606_clues(room_id, round_no, seat_no, clue_text, was_skipped)
      values (p_room, v_room.round_no, v_room.clue_current_seat, null, true);
    update public.intel606_rooms
      set clue_current_seat=(select min(m.seat_no) from public.intel606_members m
             where m.room_id=p_room and m.seat_no>v_room.clue_current_seat),
          clue_completed_at=(case when exists(
            select 1 from public.intel606_members m where m.room_id=p_room and m.seat_no>v_room.clue_current_seat
          ) then null else clock_timestamp() end)
      where id=p_room;
  elsif p_action = 'unmask' and v_room.phase = 'discussion' then
    update public.intel606_rooms set phase='undercover' where id=p_room;
  elsif p_action = 'answer' and v_room.phase = 'undercover' then
    update public.intel606_rooms set phase='answer' where id=p_room;
  elsif p_action = 'next' and v_room.phase = 'answer' then
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='lobby',round_no=round_no+1,current_card_id=null,current_card_snapshot=null,dice_rolled_at=null,clue_current_seat=null,clue_completed_at=null where id=p_room;
  elsif p_action = 'close' and v_room.phase <> 'closed' then
    update public.intel606_rooms set phase='closed' where id=p_room;
  else
    raise exception '目前階段不允許執行這個操作';
  end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 玩家送出線索：同一時間只有輪到的身分能提交，並由資料庫推到下一個座位。
-- 房間列 FOR UPDATE 可序列化重複送出／同時操作。
create or replace function public.intel606_submit_clue(p_room uuid,p_text text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_seat integer;
  v_text text;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if v_room.play_mode <> 'remote' or v_room.phase <> 'clue' then
    raise exception '目前不是遠距正式發言階段';
  end if;
  if v_room.clue_completed_at is not null or v_room.clue_current_seat is null then
    raise exception '本輪線索階段已完成';
  end if;
  select m.seat_no into v_seat from public.intel606_members m
    where m.room_id=p_room and m.user_id=auth.uid();
  if v_seat is null then raise exception '你不是這個房間的正式玩家'; end if;
  if v_seat <> v_room.clue_current_seat then raise exception '尚未輪到你的發言順序'; end if;
  v_text := btrim(coalesce(p_text,''));
  if char_length(v_text)<1 or char_length(v_text)>80 then raise exception '線索請輸入1～80字'; end if;
  insert into intelligence_private.intel606_clues(room_id,round_no,seat_no,clue_text,was_skipped)
    values(p_room,v_room.round_no,v_seat,v_text,false);
  update public.intel606_rooms
    set clue_current_seat=(select min(m.seat_no) from public.intel606_members m
      where m.room_id=p_room and m.seat_no>v_seat),
      clue_completed_at=(case when exists(
        select 1 from public.intel606_members m where m.room_id=p_room and m.seat_no>v_seat
      ) then null else clock_timestamp() end),
      version=version+1, updated_at=now()
    where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 與 Data API 2026/10/30 之後的明確 GRANT 規則相容。
revoke all on function public.intel606_room_state(uuid) from public,anon,authenticated;
revoke all on function public.intel606_host_action(uuid,text) from public,anon,authenticated;
revoke all on function public.intel606_submit_clue(uuid,text) from public,anon,authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
grant execute on function public.intel606_host_action(uuid,text) to authenticated;
grant execute on function public.intel606_submit_clue(uuid,text) to authenticated;
notify pgrst,'reload schema';

-- 606 情報局 v2.6.0 R2 → R3｜遠距自由討論與計時系統
-- 只在 v2.6.0 R2 已部署且所有房間處於 lobby/closed 時使用。
-- 不刪除既有情報卡、房間與成員；近距 discussion 流程保持不變。
-- 機密訊息存放 intelligence_private，僅可透過受權限驗證的 RPC 讀取。
-- 計時由資料庫 clock_timestamp 驗證，不依賴任一台裝置的本地時鐘。
-- 期限到達後，任何合法參與者下一次呼叫 room_state 都會原子化切換到 vote_pending；
-- 全部裝置離線時資料列不會由排程立即改寫，但不會允許到期後再發訊息。
-- 討論完成後停在 vote_pending，等待後續 R4 投票模組；不可提前揭曉臥底。
do $guard$
begin
  if exists(select 1 from public.intel606_rooms where phase not in ('lobby','closed')) then
    raise exception 'R3 升級中止：尚有進行中的房間。請結束房間再執行，資料不會變動。';
  end if;
end
$guard$;

alter table public.intel606_rooms
  add column if not exists chat_started_at timestamptz,
  add column if not exists chat_deadline_at timestamptz,
  add column if not exists chat_paused boolean not null default false,
  add column if not exists chat_remaining_seconds integer;

alter table public.intel606_rooms drop constraint if exists intel606_rooms_chat_remaining_check;
alter table public.intel606_rooms add constraint intel606_rooms_chat_remaining_check
  check (chat_remaining_seconds is null or chat_remaining_seconds between 0 and 1800);
alter table public.intel606_rooms drop constraint if exists intel606_rooms_phase_check;
alter table public.intel606_rooms add constraint intel606_rooms_phase_check
  check (phase in ('lobby','identity','dossier','clue','chat','vote_pending','discussion','undercover','answer','closed'));

-- 用獨立私密資料表儲存每輪討論，主控也只能在討論階段查看公開訊息。
create table if not exists intelligence_private.intel606_messages (
  id bigint generated by default as identity primary key,
  room_id uuid not null references public.intel606_rooms(id) on delete cascade,
  round_no integer not null check(round_no > 0),
  user_id uuid not null references auth.users(id) on delete cascade,
  seat_no integer not null check(seat_no between 1 and 8),
  message_text text not null check(char_length(btrim(message_text)) between 1 and 200),
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists intel606_messages_room_round_id_idx
  on intelligence_private.intel606_messages(room_id,round_no,id desc);
create index if not exists intel606_messages_sender_idx
  on intelligence_private.intel606_messages(room_id,round_no,user_id,created_at desc);
revoke all on intelligence_private.intel606_messages from public,anon,authenticated;
alter table intelligence_private.intel606_messages enable row level security;

-- 讀取狀態的單一授權出口，延續 R2 的身分隔離。
create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_message_total integer := 0;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  -- 實際伺服器時鐘是唯一的截止依據。任何合法玩家讀取狀態時
  -- 都可觸發過期轉換，無須主控端保持連線；資料庫交易確保只執行一次。
  if v_room.play_mode='remote' and v_room.phase='chat'
     and v_room.discussion_mode='timed' and not v_room.chat_paused
     and v_room.chat_deadline_at is not null
     and clock_timestamp() >= v_room.chat_deadline_at then
    update public.intel606_rooms
      set phase='vote_pending', chat_deadline_at=null,chat_remaining_seconds=0,
          version=version+1,updated_at=now()
      where id=p_room and phase='chat' and not chat_paused
        and chat_deadline_at is not null and chat_deadline_at<=clock_timestamp();
    select * into v_room from public.intel606_rooms where id=p_room;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','chat','vote_pending','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','chat','vote_pending','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') then v_unmasked := v_secret.undercover_seat; end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','chat','vote_pending','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', c.clue_text, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;

  if v_room.play_mode='remote' and v_room.phase in ('chat','vote_pending') then
    select count(*) into v_message_total from intelligence_private.intel606_messages
      where room_id=p_room and round_no=v_room.round_no;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'seat',q.seat_no, 'text',q.message_text, 'sent_at',q.created_at
    ) order by q.id),'[]'::jsonb)
      into v_messages
    from (
      select id,seat_no,message_text,created_at
        from intelligence_private.intel606_messages
        where room_id=p_room and round_no=v_room.round_no
        order by id desc limit 100
    ) q;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'discussion_seconds', v_room.discussion_seconds,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending') then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending') and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'chat_messages', v_messages, 'chat_message_total', v_message_total,
    'chat_started_at', case when v_room.play_mode='remote' then v_room.chat_started_at else null end,
    'chat_deadline_at', case when v_room.play_mode='remote' then v_room.chat_deadline_at else null end,
    'chat_paused', (v_room.play_mode='remote' and v_room.chat_paused),
    'chat_remaining_seconds', case when v_room.play_mode='remote' then v_room.chat_remaining_seconds else null end,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;


-- 主控獨立管理遠距討論，避免改寫 R2 的近距 host_action 與揭曉流程。
create or replace function public.intel606_chat_control(p_room uuid,p_action text,p_seconds integer default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_now timestamptz;
  v_rem integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可管理討論'; end if;
  if v_room.play_mode <> 'remote' then raise exception '近距模式不使用線上討論控制'; end if;
  v_now := clock_timestamp();
  if p_action='start' then
    if v_room.phase<>'clue' or v_room.clue_completed_at is null then
      raise exception '請先完成所有玩家的正式線索';
    end if;
    update public.intel606_rooms set
      phase='chat',chat_started_at=v_now,chat_paused=false,
      chat_remaining_seconds=case when discussion_mode='timed' then discussion_seconds else null end,
      chat_deadline_at=case when discussion_mode='timed' then v_now+make_interval(secs=>discussion_seconds) else null end,
      version=version+1,updated_at=now()
      where id=p_room;
  else
    if v_room.phase<>'chat' then raise exception '目前不在自由討論階段'; end if;
    -- 到期即封存，不能在期限後用「延長／暫停」重新開啟已結束的討論。
    if v_room.discussion_mode='timed' and not v_room.chat_paused
       and v_room.chat_deadline_at is not null and v_now>=v_room.chat_deadline_at then
      update public.intel606_rooms set phase='vote_pending',chat_deadline_at=null,
        chat_remaining_seconds=0,version=version+1,updated_at=now() where id=p_room;
      return public.intel606_room_state(p_room);
    end if;
    if p_action='end' then
      update public.intel606_rooms set phase='vote_pending',chat_deadline_at=null,
        chat_paused=false, chat_remaining_seconds=case when discussion_mode='timed' then
          case when v_room.chat_paused then v_room.chat_remaining_seconds
               else greatest(0,ceil(extract(epoch from v_room.chat_deadline_at-v_now))::integer) end
          else null end,
        version=version+1,updated_at=now() where id=p_room;
    elsif p_action='pause' and v_room.discussion_mode='timed' and not v_room.chat_paused then
      v_rem := greatest(0,ceil(extract(epoch from v_room.chat_deadline_at-v_now))::integer);
      update public.intel606_rooms set chat_paused=true,chat_deadline_at=null,
        chat_remaining_seconds=v_rem,version=version+1,updated_at=now() where id=p_room;
    elsif p_action='resume' and v_room.discussion_mode='timed' and v_room.chat_paused then
      update public.intel606_rooms set chat_paused=false,
        chat_deadline_at=v_now+make_interval(secs=>v_room.chat_remaining_seconds),
        version=version+1,updated_at=now() where id=p_room;
    elsif p_action='extend' and v_room.discussion_mode='timed' and p_seconds in (60,180) then
      v_rem := case when v_room.chat_paused then v_room.chat_remaining_seconds
        else greatest(0,ceil(extract(epoch from v_room.chat_deadline_at-v_now))::integer) end;
      if v_rem+p_seconds>1800 then raise exception '剩餘時間不可超過30分鐘'; end if;
      update public.intel606_rooms set
        chat_remaining_seconds=case when chat_paused then v_rem+p_seconds else chat_remaining_seconds end,
        chat_deadline_at=case when chat_paused then null else chat_deadline_at+make_interval(secs=>p_seconds) end,
        version=version+1,updated_at=now() where id=p_room;
    else
      raise exception '此討論模式或階段不支援該項操作';
    end if;
  end if;
  return public.intel606_room_state(p_room);
end;
$$;

-- 傳送聊天訊息：對房間列加鎖，避免期限瞬間的競態條件。
create or replace function public.intel606_send_chat(p_room uuid,p_text text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_seat integer;
  v_text text;
  v_now timestamptz;
  v_last timestamptz;
  v_total integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if v_room.play_mode<>'remote' or v_room.phase<>'chat' then
    raise exception '目前尚未開放自由討論';
  end if;
  select seat_no into v_seat from public.intel606_members
    where room_id=p_room and user_id=auth.uid();
  if v_seat is null then raise exception '只有本房間正式玩家能發送訊息'; end if;
  v_now := clock_timestamp();
  if v_room.discussion_mode='timed' then
    if v_room.chat_paused then raise exception '討論已暫停，暫時無法傳送訊息'; end if;
    if v_room.chat_deadline_at is null or v_now>=v_room.chat_deadline_at then
      -- 到期後無條件拒絕訊息；下次合法讀取狀態將推進至 vote_pending。
      raise exception '討論時間已結束，訊息未送出';
    end if;
  end if;
  v_text:=btrim(coalesce(p_text,''));
  if char_length(v_text)<1 or char_length(v_text)>200 then raise exception '討論訊息請輸入1～200字'; end if;
  select max(created_at) into v_last from intelligence_private.intel606_messages
    where room_id=p_room and round_no=v_room.round_no and user_id=auth.uid();
  if v_last is not null and v_now-v_last<interval '2 seconds' then
    raise exception '請稍候2秒再發送下一則訊息';
  end if;
  select count(*) into v_total from intelligence_private.intel606_messages
    where room_id=p_room and round_no=v_room.round_no;
  if v_total>=200 then raise exception '本輪討論已達200則訊息上限'; end if;
  insert into intelligence_private.intel606_messages(room_id,round_no,user_id,seat_no,message_text,created_at)
    values(p_room,v_room.round_no,auth.uid(),v_seat,v_text,v_now);
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

revoke all on function public.intel606_room_state(uuid) from public,anon,authenticated;
revoke all on function public.intel606_chat_control(uuid,text,integer) from public,anon,authenticated;
revoke all on function public.intel606_send_chat(uuid,text) from public,anon,authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
grant execute on function public.intel606_chat_control(uuid,text,integer) to authenticated;
grant execute on function public.intel606_send_chat(uuid,text) to authenticated;
notify pgrst,'reload schema';


-- R4：投票與平票處理
-- 606 情報局 v2.6.0 R3 → R4｜秘密投票與最高票平票重投
-- 適用於已部署 R3 的資料庫。請先結束所有進行中的房間並備份資料。
-- 不刪除情報卡、房間或成員；近距模式維持原流程。
-- 投票紀錄只儲存在 intelligence_private；所有人（包括主控）投票期間只看到進度。
-- 第二輪仍平票：指認失敗；R4 結束於 vote_result，R5 才揭曉真正臥底。
do $guard$
begin
  if exists(select 1 from public.intel606_rooms where phase not in ('lobby','closed')) then
    raise exception 'R4 升級中止：尚有進行中的房間。請先結束房間；此次升級會回滾，不會刪除資料。';
  end if;
end
$guard$;

alter table public.intel606_rooms
  add column if not exists vote_round integer not null default 0,
  add column if not exists vote_candidates integer[],
  add column if not exists vote_result_type text,
  add column if not exists vote_result_seat integer,
  add column if not exists vote_finished_at timestamptz;
alter table public.intel606_rooms drop constraint if exists intel606_rooms_vote_round_check;
alter table public.intel606_rooms add constraint intel606_rooms_vote_round_check check (vote_round between 0 and 2);
alter table public.intel606_rooms drop constraint if exists intel606_rooms_vote_result_type_check;
alter table public.intel606_rooms add constraint intel606_rooms_vote_result_type_check
  check (vote_result_type is null or vote_result_type in ('identified','tie','no_votes'));
alter table public.intel606_rooms drop constraint if exists intel606_rooms_vote_result_seat_check;
alter table public.intel606_rooms add constraint intel606_rooms_vote_result_seat_check
  check (vote_result_seat is null or vote_result_seat between 1 and 8);
alter table public.intel606_rooms drop constraint if exists intel606_rooms_phase_check;
alter table public.intel606_rooms add constraint intel606_rooms_phase_check
  check (phase in ('lobby','identity','dossier','clue','chat','vote_pending','vote_1','vote_2','vote_result','discussion','undercover','answer','closed'));

create table if not exists intelligence_private.intel606_votes (
  room_id uuid not null,
  round_no integer not null check(round_no > 0),
  ballot_round integer not null check(ballot_round in (1,2)),
  user_id uuid not null,
  voter_seat integer not null check(voter_seat between 1 and 8),
  target_seat integer not null check(target_seat between 1 and 8),
  created_at timestamptz not null default clock_timestamp(),
  primary key(room_id,round_no,ballot_round,user_id),
  foreign key (room_id,user_id) references public.intel606_members(room_id,user_id) on delete cascade,
  foreign key (room_id,target_seat) references public.intel606_members(room_id,seat_no) on delete cascade,
  constraint intel606_votes_not_self check (voter_seat<>target_seat)
);
create index if not exists intel606_votes_count_idx on intelligence_private.intel606_votes(room_id,round_no,ballot_round,target_seat);
revoke all on intelligence_private.intel606_votes from public,anon,authenticated;
alter table intelligence_private.intel606_votes enable row level security;

create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_message_total integer := 0;
  v_vote_count integer := 0;
  v_vote_expected integer := 0;
  v_vote_mine boolean := false;
  v_vote_first_summary jsonb := '[]'::jsonb;
  v_vote_second_summary jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  -- 實際伺服器時鐘是唯一的截止依據。任何合法玩家讀取狀態時
  -- 都可觸發過期轉換，無須主控端保持連線；資料庫交易確保只執行一次。
  if v_room.play_mode='remote' and v_room.phase='chat'
     and v_room.discussion_mode='timed' and not v_room.chat_paused
     and v_room.chat_deadline_at is not null
     and clock_timestamp() >= v_room.chat_deadline_at then
    update public.intel606_rooms
      set phase='vote_pending', chat_deadline_at=null,chat_remaining_seconds=0,
          version=version+1,updated_at=now()
      where id=p_room and phase='chat' and not chat_paused
        and chat_deadline_at is not null and chat_deadline_at<=clock_timestamp();
    select * into v_room from public.intel606_rooms where id=p_room;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') then v_unmasked := v_secret.undercover_seat; end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', c.clue_text, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;

  if v_room.play_mode='remote' and v_room.phase in ('chat','vote_pending','vote_1','vote_2','vote_result') then
    select count(*) into v_message_total from intelligence_private.intel606_messages
      where room_id=p_room and round_no=v_room.round_no;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'seat',q.seat_no, 'text',q.message_text, 'sent_at',q.created_at
    ) order by q.id),'[]'::jsonb)
      into v_messages
    from (
      select id,seat_no,message_text,created_at
        from intelligence_private.intel606_messages
        where room_id=p_room and round_no=v_room.round_no
        order by id desc limit 100
    ) q;
  end if;
  if v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result') then
    select count(*) into v_vote_expected from public.intel606_members where room_id=p_room;
    if v_room.phase in ('vote_1','vote_2') then
      select count(*) into v_vote_count from intelligence_private.intel606_votes
        where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
      if v_member.user_id is not null then
        select exists(select 1 from intelligence_private.intel606_votes
          where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
            and user_id=auth.uid()) into v_vote_mine;
      end if;
    end if;
    -- 第一輪必須完成後才能公開統計；第二輪票數直到第二輪封存才可公開。
    if v_room.phase in ('vote_2','vote_result') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_first_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=1
              group by target_seat) s;
    end if;
    if v_room.phase='vote_result' then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_second_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=2
              group by target_seat) s;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'discussion_seconds', v_room.discussion_seconds,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'chat_messages', v_messages, 'chat_message_total', v_message_total,
    'chat_started_at', case when v_room.play_mode='remote' then v_room.chat_started_at else null end,
    'chat_deadline_at', case when v_room.play_mode='remote' then v_room.chat_deadline_at else null end,
    'chat_paused', (v_room.play_mode='remote' and v_room.chat_paused),
    'chat_remaining_seconds', case when v_room.play_mode='remote' then v_room.chat_remaining_seconds else null end,
    'vote_round',case when v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result') then v_room.vote_round else 0 end,
    'vote_candidates',case when v_room.play_mode='remote' and v_room.phase in ('vote_2','vote_result') then to_jsonb(v_room.vote_candidates) else null end,
    'vote_cast_count',v_vote_count, 'vote_expected_count',v_vote_expected, 'vote_my_submitted',v_vote_mine,
    'vote_first_summary',v_vote_first_summary,'vote_second_summary',v_vote_second_summary,
    'vote_result_type',case when v_room.phase='vote_result' then v_room.vote_result_type else null end,
    'vote_result_seat',case when v_room.phase='vote_result' then v_room.vote_result_seat else null end,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

-- 此函式僅供受控 RPC 在持有房間列鎖時呼叫，不開放給使用者直接執行。
create or replace function intelligence_private.intel606_finalize_vote_locked(p_room uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_high integer;
  v_top integer[];
  v_count integer;
begin
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.play_mode<>'remote' or v_room.phase not in ('vote_1','vote_2') then
    raise exception '目前無法結算投票';
  end if;
  select count(*)::integer into v_count from intelligence_private.intel606_votes
    where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
  if v_count=0 then
    update public.intel606_rooms set phase='vote_result',vote_result_type='no_votes',
      vote_result_seat=null,vote_finished_at=clock_timestamp(),version=version+1,updated_at=now()
      where id=p_room;
    return;
  end if;
  select max(tally) into v_high from (
    select count(*)::integer tally from intelligence_private.intel606_votes
    where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
    group by target_seat
  ) counts;
  select array_agg(s.target_seat order by s.target_seat) into v_top
    from (
      select target_seat,count(*)::integer tally from intelligence_private.intel606_votes
      where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
      group by target_seat
    ) s where s.tally=v_high;
  if coalesce(array_length(v_top,1),0)=1 then
    update public.intel606_rooms set phase='vote_result',vote_result_type='identified',
      vote_result_seat=v_top[1],vote_finished_at=clock_timestamp(),
      version=version+1,updated_at=now() where id=p_room;
  elsif v_room.vote_round=1 then
    update public.intel606_rooms set phase='vote_2',vote_round=2,vote_candidates=v_top,
      version=version+1,updated_at=now() where id=p_room;
  else
    update public.intel606_rooms set phase='vote_result',vote_result_type='tie',
      vote_result_seat=null,vote_finished_at=clock_timestamp(),
      version=version+1,updated_at=now() where id=p_room;
  end if;
end;
$$;
revoke all on function intelligence_private.intel606_finalize_vote_locked(uuid) from public,anon,authenticated;

-- 主控開啟投票或提前封存未完成投票；所有計票皆由私密函式處理。
create or replace function public.intel606_vote_control(p_room uuid,p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id<>auth.uid() then raise exception '只有主控端可以管理投票'; end if;
  if v_room.play_mode<>'remote' then raise exception '近距模式不使用線上投票'; end if;
  if p_action='start' then
    if v_room.phase<>'vote_pending' then raise exception '目前尚未可以開始投票'; end if;
    update public.intel606_rooms set phase='vote_1',vote_round=1,vote_candidates=null,
      vote_result_type=null,vote_result_seat=null,vote_finished_at=null,
      version=version+1,updated_at=now() where id=p_room;
  elsif p_action='finish' then
    if v_room.phase not in ('vote_1','vote_2') then raise exception '目前沒有可以封存的選票'; end if;
    perform intelligence_private.intel606_finalize_vote_locked(p_room);
  else
    raise exception '無效的投票管理操作';
  end if;
  return public.intel606_room_state(p_room);
end;
$$;

-- 同一個人同一輪投票只能一次；房間列鎖防止同時按鈕與主控結算競態。
create or replace function public.intel606_cast_vote(p_room uuid,p_target_seat integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_voter integer;
  v_votes integer;
  v_expected integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.play_mode<>'remote' or v_room.phase not in ('vote_1','vote_2') then
    raise exception '目前沒有開放投票';
  end if;
  select seat_no into v_voter from public.intel606_members where room_id=p_room and user_id=auth.uid();
  if v_voter is null then raise exception '只有正式玩家可以投票'; end if;
  if p_target_seat is null or p_target_seat=v_voter then raise exception '不可投給自己'; end if;
  if not exists(select 1 from public.intel606_members where room_id=p_room and seat_no=p_target_seat) then
    raise exception '此候選人不在房間';
  end if;
  if v_room.phase='vote_2' and not (p_target_seat=any(coalesce(v_room.vote_candidates,'{}'::integer[]))) then
    raise exception '第二輪只能指認第一輪並列最高票的候選人';
  end if;
  if exists(select 1 from intelligence_private.intel606_votes
      where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round and user_id=auth.uid()) then
    raise exception '本輪已提交選票，無法重複投票';
  end if;
  insert into intelligence_private.intel606_votes
    (room_id,round_no,ballot_round,user_id,voter_seat,target_seat)
    values(p_room,v_room.round_no,v_room.vote_round,auth.uid(),v_voter,p_target_seat);
  select count(*)::integer into v_votes from intelligence_private.intel606_votes
    where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
  select count(*)::integer into v_expected from public.intel606_members where room_id=p_room;
  if v_votes=v_expected then
    perform intelligence_private.intel606_finalize_vote_locked(p_room);
  else
    update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  end if;
  return public.intel606_room_state(p_room);
end;
$$;
revoke all on function public.intel606_room_state(uuid) from public,anon,authenticated;
revoke all on function public.intel606_vote_control(uuid,text) from public,anon,authenticated;
revoke all on function public.intel606_cast_vote(uuid,integer) from public,anon,authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
grant execute on function public.intel606_vote_control(uuid,text) to authenticated;
grant execute on function public.intel606_cast_vote(uuid,integer) to authenticated;
notify pgrst,'reload schema';

-- ===================================================
-- v2.6.0 R5 整合項目（同一交易）
-- ===================================================
-- 606 情報局 v2.6.0 R4 → R5｜遠距臥底揭曉、私人猜測與勝負結算
-- 只在已部署 R4 的專案執行；全新部署請改用 R5-full.sql。
-- 不刪除情報卡、成員、房間與既有選票。近距模式不更動。
-- 遊戲進行中禁止執行，先結束或關閉遊戲房間。


do $guard$
begin
  if exists(select 1 from public.intel606_rooms where phase not in ('lobby','closed')) then
    raise exception 'R5 升級中止：尚有進行中的房間。請先結束房間，本交易將回滾且不刪資料。';
  end if;
end
$guard$;

alter table public.intel606_rooms
  add column if not exists guess_status text,
  add column if not exists guess_finished_at timestamptz;
alter table public.intel606_rooms drop constraint if exists intel606_rooms_guess_status_check;
alter table public.intel606_rooms add constraint intel606_rooms_guess_status_check
  check (guess_status is null or guess_status in ('submitted','skipped'));
alter table public.intel606_rooms drop constraint if exists intel606_rooms_phase_check;
alter table public.intel606_rooms add constraint intel606_rooms_phase_check
  check (phase in ('lobby','identity','dossier','clue','chat','vote_pending','vote_1','vote_2',
                  'vote_result','reveal','guess','discussion','undercover','answer','closed'));

create table if not exists intelligence_private.intel606_guesses (
  room_id uuid not null,
  round_no integer not null check (round_no>0),
  user_id uuid not null,
  guess_code text not null check (guess_code ~ '^[A-D][1-4]$'),
  created_at timestamptz not null default clock_timestamp(),
  primary key (room_id,round_no),
  foreign key (room_id,user_id) references public.intel606_members(room_id,user_id) on delete cascade
);
revoke all on intelligence_private.intel606_guesses from public,anon,authenticated;
alter table intelligence_private.intel606_guesses enable row level security;

-- 房間狀態：投票封存後才允許公開臥底；答案只在 answer 階段公開。
-- 正式代碼仍僅允許情報員私下查看，直到公布答案。
create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_message_total integer := 0;
  v_vote_count integer := 0;
  v_vote_expected integer := 0;
  v_vote_mine boolean := false;
  v_vote_first_summary jsonb := '[]'::jsonb;
  v_vote_second_summary jsonb := '[]'::jsonb;
  v_guess_code text := null;
  v_identified_correct boolean := null;
  v_guess_correct boolean := null;
  v_winner text := null;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  -- 實際伺服器時鐘是唯一的截止依據。任何合法玩家讀取狀態時
  -- 都可觸發過期轉換，無須主控端保持連線；資料庫交易確保只執行一次。
  if v_room.play_mode='remote' and v_room.phase='chat'
     and v_room.discussion_mode='timed' and not v_room.chat_paused
     and v_room.chat_deadline_at is not null
     and clock_timestamp() >= v_room.chat_deadline_at then
    update public.intel606_rooms
      set phase='vote_pending', chat_deadline_at=null,chat_remaining_seconds=0,
          version=version+1,updated_at=now()
      where id=p_room and phase='chat' and not chat_paused
        and chat_deadline_at is not null and chat_deadline_at<=clock_timestamp();
    select * into v_room from public.intel606_rooms where id=p_room;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') or
       (v_room.play_mode='remote' and v_room.phase in ('reveal','guess')) then
      v_unmasked := v_secret.undercover_seat;
    end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode='remote' and v_room.phase='answer' then
    select guess_code into v_guess_code from intelligence_private.intel606_guesses
      where room_id=p_room and round_no=v_room.round_no;
    v_identified_correct := v_room.vote_result_type='identified'
      and v_room.vote_result_seat=v_secret.undercover_seat;
    v_guess_correct := v_guess_code is not null and v_guess_code=v_secret.secret_code;
    v_winner := case when v_identified_correct and not v_guess_correct then 'agents' else 'undercover' end;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', c.clue_text, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;

  if v_room.play_mode='remote' and v_room.phase in ('chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_message_total from intelligence_private.intel606_messages
      where room_id=p_room and round_no=v_room.round_no;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'seat',q.seat_no, 'text',q.message_text, 'sent_at',q.created_at
    ) order by q.id),'[]'::jsonb)
      into v_messages
    from (
      select id,seat_no,message_text,created_at
        from intelligence_private.intel606_messages
        where room_id=p_room and round_no=v_room.round_no
        order by id desc limit 100
    ) q;
  end if;
  if v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_vote_expected from public.intel606_members where room_id=p_room;
    if v_room.phase in ('vote_1','vote_2') then
      select count(*) into v_vote_count from intelligence_private.intel606_votes
        where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
      if v_member.user_id is not null then
        select exists(select 1 from intelligence_private.intel606_votes
          where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
            and user_id=auth.uid()) into v_vote_mine;
      end if;
    end if;
    -- 第一輪必須完成後才能公開統計；第二輪票數直到第二輪封存才可公開。
    if v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_first_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=1
              group by target_seat) s;
    end if;
    if v_room.phase in ('vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_second_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=2
              group by target_seat) s;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'discussion_seconds', v_room.discussion_seconds,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'chat_messages', v_messages, 'chat_message_total', v_message_total,
    'chat_started_at', case when v_room.play_mode='remote' then v_room.chat_started_at else null end,
    'chat_deadline_at', case when v_room.play_mode='remote' then v_room.chat_deadline_at else null end,
    'chat_paused', (v_room.play_mode='remote' and v_room.chat_paused),
    'chat_remaining_seconds', case when v_room.play_mode='remote' then v_room.chat_remaining_seconds else null end,
    'vote_round',case when v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then v_room.vote_round else 0 end,
    'vote_candidates',case when v_room.play_mode='remote' and v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then to_jsonb(v_room.vote_candidates) else null end,
    'vote_cast_count',v_vote_count, 'vote_expected_count',v_vote_expected, 'vote_my_submitted',v_vote_mine,
    'vote_first_summary',v_vote_first_summary,'vote_second_summary',v_vote_second_summary,
    'vote_result_type',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_type else null end,
    'vote_result_seat',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_seat else null end,
    'guess_status',case when v_room.play_mode='remote' and v_room.phase in ('reveal','guess','answer') then v_room.guess_status else null end,
    'guess_code',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_code else null end,
    'identified_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_identified_correct else null end,
    'guess_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_correct else null end,
    'winner',case when v_room.play_mode='remote' and v_room.phase='answer' then v_winner else null end,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

-- 主控只能依序揭曉 → 開放猜測；如臥底失聯可經確認跳過猜測。
create or replace function public.intel606_r5_control(p_room uuid,p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id<>auth.uid() then raise exception '只有主控端可以操作揭曉階段'; end if;
  if v_room.play_mode<>'remote' then raise exception '近距模式不使用遠距揭曉流程'; end if;
  if p_action='reveal' and v_room.phase='vote_result' then
    update public.intel606_rooms set phase='reveal',guess_status=null,guess_finished_at=null,
      version=version+1,updated_at=now() where id=p_room;
  elsif p_action='open_guess' and v_room.phase='reveal' then
    update public.intel606_rooms set phase='guess',version=version+1,updated_at=now()
      where id=p_room;
  elsif p_action='skip_guess' and v_room.phase='guess' then
    -- 跳過視為臥底未猜中；若指認本來失敗，仍然由臥底獲勝。
    update public.intel606_rooms set phase='answer',guess_status='skipped',
      guess_finished_at=clock_timestamp(),version=version+1,updated_at=now()
      where id=p_room;
  else
    raise exception '此階段無法執行指定操作';
  end if;
  return public.intel606_room_state(p_room);
end;
$$;

-- 僅真正臥底可猜測；資料庫列鎖確保只接受一次猜測。
create or replace function public.intel606_submit_guess(p_room uuid,p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_spy_seat integer;
  v_my_seat integer;
  v_code text;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.play_mode<>'remote' or v_room.phase<>'guess' then
    raise exception '目前沒有開放最後猜測';
  end if;
  select seat_no into v_my_seat from public.intel606_members
    where room_id=p_room and user_id=auth.uid();
  select undercover_seat into v_spy_seat from intelligence_private.intel606_secrets
    where room_id=p_room;
  if v_my_seat is null or v_spy_seat is null or v_my_seat<>v_spy_seat then
    raise exception '只有本輪真正臥底可以提交猜測';
  end if;
  if v_room.guess_status is not null or exists(
    select 1 from intelligence_private.intel606_guesses
    where room_id=p_room and round_no=v_room.round_no) then
    raise exception '本輪已經封存最後猜測';
  end if;
  v_code := upper(btrim(coalesce(p_code,'')));
  if (v_room.board_size=3 and v_code !~ '^[A-C][1-3]$') or
     (v_room.board_size=4 and v_code !~ '^[A-D][1-4]$') then
    raise exception '機密代號不符合情報卡宮格';
  end if;
  insert into intelligence_private.intel606_guesses(room_id,round_no,user_id,guess_code)
    values(p_room,v_room.round_no,auth.uid(),v_code);
  update public.intel606_rooms set phase='answer',guess_status='submitted',
    guess_finished_at=clock_timestamp(),version=version+1,updated_at=now()
    where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

revoke all on function public.intel606_room_state(uuid) from public,anon,authenticated;
revoke all on function public.intel606_r5_control(uuid,text) from public,anon,authenticated;
revoke all on function public.intel606_submit_guess(uuid,text) from public,anon,authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
grant execute on function public.intel606_r5_control(uuid,text) to authenticated;
grant execute on function public.intel606_submit_guess(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;

-- 整合階段｜主控兼玩家、自動主持、我的房間、每輪隨機情報卡排列
-- 以下沿用已驗收的 v2.7.0 資料庫函式與權限。
-- 建議在測試專案先行驗證，執行前備份；不刪除既有情報卡或房間。
-- 當有進行中房間時拒絕升級，避免局內狀態被改寫。
begin;

do $guard$
begin
  if exists (select 1 from public.intel606_rooms where phase not in ('lobby','closed')) then
    raise exception 'v2.7.0 升級中止：有進行中的房間。請從「我的房間」先結束舊房間。';
  end if;
end $guard$;

alter table public.intel606_rooms
  add column if not exists host_plays boolean not null default false,
  add column if not exists host_mode text not null default 'manual',
  add column if not exists auto_phase_at timestamptz;
alter table public.intel606_rooms drop constraint if exists intel606_host_mode_check;
alter table public.intel606_rooms add constraint intel606_host_mode_check
  check (host_mode in ('manual','auto') and (host_mode <> 'auto' or play_mode = 'remote'));

-- 原始資料庫中的 cells 仍然是一份9項／16項的內容清單。
-- 真正抽中情報卡時，才在資料庫生成一次新順序，並儲存在房間快照。
-- 使用 Fisher-Yates 打亂，每輪必須重新執行，避免每支裝置的結果不同。
create or replace function intelligence_private.intel606_randomized_card(p_card uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_card public.intel606_cards%rowtype;
  v_cells text[];
  v_i integer;
  v_j integer;
  v_tmp text;
begin
  select * into v_card from public.intel606_cards where id = p_card;
  if not found then raise exception '找不到情報卡'; end if;
  select array_agg(value order by ordinality) into v_cells
    from jsonb_array_elements_text(v_card.cells) with ordinality as item(value,ordinality);
  if coalesce(array_length(v_cells,1),0) <> v_card.board_size*v_card.board_size then
    raise exception '情報卡項目數量不正確';
  end if;
  for v_i in reverse array_length(v_cells,1)..2 loop
    v_j := intelligence_private.intel606_rand(v_i) + 1;
    v_tmp:=v_cells[v_i]; v_cells[v_i]:=v_cells[v_j]; v_cells[v_j]:=v_tmp;
  end loop;
  return jsonb_build_object('id',v_card.id,'title',v_card.title,
                            'category',v_card.category,'cells',to_jsonb(v_cells));
end;
$$;
revoke all on function intelligence_private.intel606_randomized_card(uuid) from public,anon,authenticated;

-- 統一用同一個 auth 身分，同時具備房主權限與正式玩家資格。
-- 房主若參與，直接占用座位1；其餘玩家從可用座位加入。
create or replace function public.intel606_create_room_v27(
  p_size integer,p_play_mode text,p_discussion_mode text,p_discussion_seconds integer,
  p_host_plays boolean,p_host_name text,p_host_mode text
)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room uuid;
  v_code text;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_i integer;
  v_try integer;
  v_name text := btrim(coalesce(p_host_name,''));
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if p_size not in (3,4) or p_size is null then raise exception '只支援3×3及4×4'; end if;
  if p_play_mode not in ('near','remote') or p_play_mode is null then raise exception '遊戲模式不正確'; end if;
  if p_discussion_mode not in ('manual','timed') or p_discussion_mode is null then raise exception '討論模式不正確'; end if;
  if p_discussion_seconds not in (180,300,480,600) or p_discussion_seconds is null then
    raise exception '討論時間只能選3、5、8或10分鐘';
  end if;
  if p_host_mode not in ('manual','auto') or p_host_mode is null then raise exception '主持方式不正確'; end if;
  if p_play_mode='near' then
    p_host_mode:='manual';p_discussion_mode:='manual';p_discussion_seconds:=300;
  end if;
  if coalesce(p_host_plays,false) and (char_length(v_name)<1 or char_length(v_name)>24) then
    raise exception '主控兼玩家時，請填寫1～24字的代稱';
  end if;
  for v_try in 1..10 loop
    v_code:='';
    for v_i in 1..6 loop
      v_code:=v_code || substr(v_alphabet,intelligence_private.intel606_rand(length(v_alphabet))+1,1);
    end loop;
    begin
      insert into public.intel606_rooms
        (room_code,host_id,board_size,play_mode,discussion_mode,discussion_seconds,host_plays,host_mode)
      values (v_code,auth.uid(),p_size,p_play_mode,p_discussion_mode,p_discussion_seconds,
              coalesce(p_host_plays,false),p_host_mode)
      returning id into v_room;
      if coalesce(p_host_plays,false) then
        insert into public.intel606_members(room_id,user_id,seat_no,display_name)
          values(v_room,auth.uid(),1,v_name);
      end if;
      return public.intel606_room_state(v_room);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception '房間代碼產生失敗，請重新嘗試';
end;
$$;

-- 我的房間：只讀取登入者自己建立的房間，返回公開管理欄位，不包含機密。
create or replace function public.intel606_list_my_rooms()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rooms jsonb;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
     'room_id',r.id,'code',r.room_code,'phase',r.phase,'round',r.round_no,
     'size',r.board_size,'play_mode',r.play_mode,'host_plays',r.host_plays,
     'host_mode',r.host_mode,'member_count',
       (select count(*) from public.intel606_members m where m.room_id=r.id),
     'updated_at',r.updated_at) order by r.updated_at desc),'[]'::jsonb)
    into v_rooms
  from (select * from public.intel606_rooms where host_id=auth.uid()
        order by updated_at desc limit 50) r;
  return v_rooms;
end;
$$;

-- 遺留房間由主控本人關閉；已關閉的舊房間可手動永久刪除。
create or replace function public.intel606_manage_owned_room(p_room uuid,p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id<>auth.uid() then raise exception '只能管理自己建立的房間'; end if;
  if p_action='close' and v_room.phase<>'closed' then
    update public.intel606_rooms set phase='closed',version=version+1,updated_at=now() where id=p_room;
  elsif p_action='delete' and v_room.phase='closed' then
    delete from public.intel606_rooms where id=p_room;
  else
    raise exception '房間目前不支援此操作';
  end if;
  return public.intel606_list_my_rooms();
end;
$$;

-- 即使主控兼玩家，也不能從房間中途被移除：由房主操作權限單獨保護。
create or replace function public.intel606_remove_member(p_room uuid,p_seat integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id<>auth.uid() then raise exception '只有房主可以移除玩家'; end if;
  if v_room.phase<>'lobby' then raise exception '遊戲開始後不能移除玩家'; end if;
  if exists(select 1 from public.intel606_members
       where room_id=p_room and seat_no=p_seat and user_id=v_room.host_id) then
    raise exception '主控兼任玩家不能被移除；請結束房間並重新建立';
  end if;
  delete from public.intel606_members where room_id=p_room and seat_no=p_seat;
  if not found then raise exception '找不到這位玩家'; end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 已驗收 v2.6.0 的主控流程，僅改為每輪抽取時才亂數排列情報卡內容。
create or replace function public.intel606_host_action(p_room uuid, p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_total integer; v_ready integer;
  v_codes text[] := '{}'::text[]; v_temp text; v_j integer; v_i integer; v_repeat integer;
  v_spy integer; v_first integer; v_second integer; v_offset integer;
  v_secret text; v_card uuid; v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可以執行此操作'; end if;
  select count(*),count(*) filter (where is_ready) into v_total,v_ready from public.intel606_members where room_id=p_room;
  if p_action = 'start' and v_room.phase = 'lobby' then
    if v_total < 3 or v_total > 8 then raise exception '需有 3～8 位玩家才能開始'; end if;
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    -- 3×3：九組代號各兩次，共18位置（6×3）。
    -- 4×4：十六組代號各三次，共48位置（8×6）。
    for v_i in 0..(v_room.board_size*v_room.board_size-1) loop
      for v_repeat in 1..(case when v_room.board_size = 3 then 2 else 3 end) loop
        v_codes := array_append(v_codes,
          substr('ABCD', (v_i % v_room.board_size)+1, 1) || ((v_i/v_room.board_size)+1)::text);
      end loop;
    end loop;
    for v_i in reverse array_length(v_codes,1)..2 loop
      v_j := intelligence_private.intel606_rand(v_i) + 1;
      v_temp := v_codes[v_i]; v_codes[v_i] := v_codes[v_j]; v_codes[v_j] := v_temp;
    end loop;
    v_spy := intelligence_private.intel606_rand(v_total) + 1;
    -- 下一輪如果編號不連續，不直接假設有 1..N，從實際成員隨機選。
    select seat_no into v_spy from public.intel606_members where room_id=p_room order by seat_no offset (v_spy-1) limit 1;
    insert into intelligence_private.intel606_secrets(room_id,undercover_seat,code_map)
      values(p_room,v_spy,to_jsonb(v_codes));
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='identity',current_card_id=null,current_card_snapshot=null,dice_rolled_at=null,clue_current_seat=null,clue_completed_at=null where id=p_room;
  elsif p_action = 'roll' and v_room.phase = 'identity' then
    if v_ready <> v_total then raise exception '請等所有玩家確認身分卡後再擲骰'; end if;
    if v_room.board_size = 3 then
      v_first := intelligence_private.intel606_rand(6) + 1;  -- 藍：1～6
      v_second := intelligence_private.intel606_rand(3) + 1; -- 紅：1/1/2/2/3/3
      v_offset := (v_first - 1) * 3 + (v_second - 1);
    else
      v_first := intelligence_private.intel606_rand(8) + 1;  -- 藍：1～8
      v_second := intelligence_private.intel606_rand(6) + 1; -- 紅：1～6，永不重擲
      v_offset := (v_first - 1) * 6 + (v_second - 1);
    end if;
    -- 以雙色骰子定位對照表的唯一位置，再由該位置讀取機密代號。
    select code_map->>v_offset into v_secret
      from intelligence_private.intel606_secrets where room_id=p_room;
    if v_secret is null then raise exception '代號對照表資料不完整，請建立新一輪任務'; end if;
    update intelligence_private.intel606_secrets
       set secret_code=v_secret,dice_first=v_first,dice_second=v_second
      where room_id=p_room;
    update public.intel606_rooms set phase='dossier',dice_rolled_at=clock_timestamp() where id=p_room;
  elsif p_action = 'draw' and v_room.phase = 'dossier' then
    select id into v_card from public.intel606_cards
       where owner_id=auth.uid() and board_size=v_room.board_size and active=true order by random() limit 1;
    if v_card is null then raise exception '沒有符合此宮格的啟用情報卡，請先建立'; end if;
    v_snapshot := intelligence_private.intel606_randomized_card(v_card);
    update public.intel606_rooms
       set phase = case when v_room.play_mode = 'remote' then 'clue' else 'discussion' end,
           current_card_id=v_card,current_card_snapshot=v_snapshot,
           clue_current_seat = case when v_room.play_mode='remote' then
             (select min(m.seat_no) from public.intel606_members m where m.room_id=p_room) else null end,
           clue_completed_at = null
      where id=p_room;
  elsif p_action = 'skip_clue' and v_room.play_mode = 'remote' and v_room.phase = 'clue' then
    if v_room.clue_current_seat is null or v_room.clue_completed_at is not null then
      raise exception '所有線索已完成，不能再跳過發言';
    end if;
    insert into intelligence_private.intel606_clues(room_id, round_no, seat_no, clue_text, was_skipped)
      values (p_room, v_room.round_no, v_room.clue_current_seat, null, true);
    update public.intel606_rooms
      set clue_current_seat=(select min(m.seat_no) from public.intel606_members m
             where m.room_id=p_room and m.seat_no>v_room.clue_current_seat),
          clue_completed_at=(case when exists(
            select 1 from public.intel606_members m where m.room_id=p_room and m.seat_no>v_room.clue_current_seat
          ) then null else clock_timestamp() end)
      where id=p_room;
  elsif p_action = 'unmask' and v_room.phase = 'discussion' then
    update public.intel606_rooms set phase='undercover' where id=p_room;
  elsif p_action = 'answer' and v_room.phase = 'undercover' then
    update public.intel606_rooms set phase='answer' where id=p_room;
  elsif p_action = 'next' and v_room.phase = 'answer' then
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='lobby',round_no=round_no+1,current_card_id=null,current_card_snapshot=null,dice_rolled_at=null,clue_current_seat=null,clue_completed_at=null where id=p_room;
  elsif p_action = 'close' and v_room.phase <> 'closed' then
    update public.intel606_rooms set phase='closed' where id=p_room;
  else
    raise exception '目前階段不允許執行這個操作';
  end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 房主若有正式座位，其秘密角色只依會員自身座位回傳；不另提供管理端秘密。
create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_message_total integer := 0;
  v_vote_count integer := 0;
  v_vote_expected integer := 0;
  v_vote_mine boolean := false;
  v_vote_first_summary jsonb := '[]'::jsonb;
  v_vote_second_summary jsonb := '[]'::jsonb;
  v_guess_code text := null;
  v_identified_correct boolean := null;
  v_guess_correct boolean := null;
  v_winner text := null;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  -- 實際伺服器時鐘是唯一的截止依據。任何合法玩家讀取狀態時
  -- 都可觸發過期轉換，無須主控端保持連線；資料庫交易確保只執行一次。
  if v_room.play_mode='remote' and v_room.phase='chat'
     and v_room.discussion_mode='timed' and not v_room.chat_paused
     and v_room.chat_deadline_at is not null
     and clock_timestamp() >= v_room.chat_deadline_at then
    update public.intel606_rooms
      set phase='vote_pending', chat_deadline_at=null,chat_remaining_seconds=0,
          version=version+1,updated_at=now()
      where id=p_room and phase='chat' and not chat_paused
        and chat_deadline_at is not null and chat_deadline_at<=clock_timestamp();
    select * into v_room from public.intel606_rooms where id=p_room;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') or
       (v_room.play_mode='remote' and v_room.phase in ('reveal','guess')) then
      v_unmasked := v_secret.undercover_seat;
    end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode='remote' and v_room.phase='answer' then
    select guess_code into v_guess_code from intelligence_private.intel606_guesses
      where room_id=p_room and round_no=v_room.round_no;
    v_identified_correct := v_room.vote_result_type='identified'
      and v_room.vote_result_seat=v_secret.undercover_seat;
    v_guess_correct := v_guess_code is not null and v_guess_code=v_secret.secret_code;
    v_winner := case when v_identified_correct and not v_guess_correct then 'agents' else 'undercover' end;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', c.clue_text, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;

  if v_room.play_mode='remote' and v_room.phase in ('chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_message_total from intelligence_private.intel606_messages
      where room_id=p_room and round_no=v_room.round_no;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'seat',q.seat_no, 'text',q.message_text, 'sent_at',q.created_at
    ) order by q.id),'[]'::jsonb)
      into v_messages
    from (
      select id,seat_no,message_text,created_at
        from intelligence_private.intel606_messages
        where room_id=p_room and round_no=v_room.round_no
        order by id desc limit 100
    ) q;
  end if;
  if v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_vote_expected from public.intel606_members where room_id=p_room;
    if v_room.phase in ('vote_1','vote_2') then
      select count(*) into v_vote_count from intelligence_private.intel606_votes
        where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
      if v_member.user_id is not null then
        select exists(select 1 from intelligence_private.intel606_votes
          where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
            and user_id=auth.uid()) into v_vote_mine;
      end if;
    end if;
    -- 第一輪必須完成後才能公開統計；第二輪票數直到第二輪封存才可公開。
    if v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_first_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=1
              group by target_seat) s;
    end if;
    if v_room.phase in ('vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_second_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=2
              group by target_seat) s;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'host_plays',v_room.host_plays, 'host_mode',v_room.host_mode,
    'auto_phase_at',case when v_room.host_mode='auto' then v_room.auto_phase_at else null end,
    'discussion_seconds', v_room.discussion_seconds,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'chat_messages', v_messages, 'chat_message_total', v_message_total,
    'chat_started_at', case when v_room.play_mode='remote' then v_room.chat_started_at else null end,
    'chat_deadline_at', case when v_room.play_mode='remote' then v_room.chat_deadline_at else null end,
    'chat_paused', (v_room.play_mode='remote' and v_room.chat_paused),
    'chat_remaining_seconds', case when v_room.play_mode='remote' then v_room.chat_remaining_seconds else null end,
    'vote_round',case when v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then v_room.vote_round else 0 end,
    'vote_candidates',case when v_room.play_mode='remote' and v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then to_jsonb(v_room.vote_candidates) else null end,
    'vote_cast_count',v_vote_count, 'vote_expected_count',v_vote_expected, 'vote_my_submitted',v_vote_mine,
    'vote_first_summary',v_vote_first_summary,'vote_second_summary',v_vote_second_summary,
    'vote_result_type',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_type else null end,
    'vote_result_seat',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_seat else null end,
    'guess_status',case when v_room.play_mode='remote' and v_room.phase in ('reveal','guess','answer') then v_room.guess_status else null end,
    'guess_code',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_code else null end,
    'identified_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_identified_correct else null end,
    'guess_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_correct else null end,
    'winner',case when v_room.play_mode='remote' and v_room.phase='answer' then v_winner else null end,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

-- 自動主持不是客戶端任意改 phase；所有跳轉均由伺服器鎖房間判斷。
-- 為避免排程外部依賴，只要任一已授權房間成員在線輪詢，就可推進；
-- 全員離線時會在有人返回的下一次讀取時推進（不保證離線時即時執行）。
create or replace function public.intel606_auto_advance(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_now timestamptz := clock_timestamp();
  v_total integer;
  v_ready integer;
  v_first integer;
  v_second integer;
  v_offset integer;
  v_code text;
  v_card uuid;
  v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if not (v_room.host_id=auth.uid() or exists(
      select 1 from public.intel606_members m where m.room_id=p_room and m.user_id=auth.uid())) then
    raise exception '無權操作此房間';
  end if;
  if v_room.host_mode<>'auto' or v_room.play_mode<>'remote' or v_room.phase='closed' then
    return public.intel606_room_state(p_room);
  end if;
  if v_room.phase='identity' then
    select count(*),count(*) filter(where is_ready) into v_total,v_ready
      from public.intel606_members where room_id=p_room;
    if v_total between 3 and 8 and v_ready=v_total then
      if v_room.board_size=3 then
        v_first:=intelligence_private.intel606_rand(6)+1;
        v_second:=intelligence_private.intel606_rand(3)+1;
        v_offset:=(v_first-1)*3+(v_second-1);
      else
        v_first:=intelligence_private.intel606_rand(8)+1;
        v_second:=intelligence_private.intel606_rand(6)+1;
        v_offset:=(v_first-1)*6+(v_second-1);
      end if;
      select code_map->>v_offset into v_code from intelligence_private.intel606_secrets where room_id=p_room;
      if v_code is null then raise exception '無法取得本輪機密代號'; end if;
      update intelligence_private.intel606_secrets
        set secret_code=v_code,dice_first=v_first,dice_second=v_second where room_id=p_room;
      update public.intel606_rooms
        set phase='dossier',dice_rolled_at=v_now,auto_phase_at=v_now,
            version=version+1,updated_at=now() where id=p_room;
    end if;
  elsif v_room.phase='dossier' and v_room.dice_rolled_at is not null
        and v_now >= v_room.dice_rolled_at+interval '4 seconds' then
    select id into v_card from public.intel606_cards
      where owner_id=v_room.host_id and board_size=v_room.board_size and active
      order by random() limit 1;
    if v_card is not null then
      v_snapshot:=intelligence_private.intel606_randomized_card(v_card);
      update public.intel606_rooms set phase='clue',current_card_id=v_card,
        current_card_snapshot=v_snapshot,
        clue_current_seat=(select min(m.seat_no) from public.intel606_members m where m.room_id=p_room),
        clue_completed_at=null,auto_phase_at=v_now,version=version+1,updated_at=now()
        where id=p_room;
    end if;
  elsif v_room.phase='clue' and v_room.clue_completed_at is not null then
    update public.intel606_rooms set phase='chat',chat_started_at=v_now,chat_paused=false,
      chat_remaining_seconds=case when discussion_mode='timed' then discussion_seconds else null end,
      chat_deadline_at=case when discussion_mode='timed' then v_now+make_interval(secs=>discussion_seconds) else null end,
      auto_phase_at=v_now,version=version+1,updated_at=now() where id=p_room;
  elsif v_room.phase='chat' and v_room.discussion_mode='timed' and not v_room.chat_paused
        and v_room.chat_deadline_at is not null and v_now>=v_room.chat_deadline_at then
    update public.intel606_rooms set phase='vote_1',chat_deadline_at=null,
      chat_remaining_seconds=0,vote_round=1,vote_candidates=null,
      vote_result_type=null,vote_result_seat=null,vote_finished_at=null,
      auto_phase_at=v_now,version=version+1,updated_at=now() where id=p_room;
  elsif v_room.phase='vote_pending' then
    update public.intel606_rooms set phase='vote_1',vote_round=1,vote_candidates=null,
      vote_result_type=null,vote_result_seat=null,vote_finished_at=null,
      auto_phase_at=v_now,version=version+1,updated_at=now() where id=p_room;
  elsif v_room.phase='vote_result' and v_room.vote_finished_at is not null
        and v_now>=v_room.vote_finished_at+interval '6 seconds' then
    update public.intel606_rooms set phase='reveal',guess_status=null,guess_finished_at=null,
      auto_phase_at=v_now,version=version+1,updated_at=now() where id=p_room;
  elsif v_room.phase='reveal' and v_room.auto_phase_at is not null
        and v_now>=v_room.auto_phase_at+interval '6 seconds' then
    update public.intel606_rooms set phase='guess',auto_phase_at=v_now,
      version=version+1,updated_at=now() where id=p_room;
  end if;
  return public.intel606_room_state(p_room);
end;
$$;

revoke all on function public.intel606_create_room_v27(integer,text,text,integer,boolean,text,text)
  from public,anon,authenticated;
revoke all on function public.intel606_list_my_rooms() from public,anon,authenticated;
revoke all on function public.intel606_manage_owned_room(uuid,text) from public,anon,authenticated;
revoke all on function public.intel606_auto_advance(uuid) from public,anon,authenticated;
revoke all on function public.intel606_room_state(uuid) from public,anon,authenticated;
revoke all on function public.intel606_host_action(uuid,text) from public,anon,authenticated;
revoke all on function public.intel606_remove_member(uuid,integer) from public,anon,authenticated;
grant execute on function public.intel606_create_room_v27(integer,text,text,integer,boolean,text,text) to authenticated;
grant execute on function public.intel606_list_my_rooms() to authenticated;
grant execute on function public.intel606_manage_owned_room(uuid,text) to authenticated;
grant execute on function public.intel606_auto_advance(uuid) to authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
grant execute on function public.intel606_host_action(uuid,text) to authenticated;
grant execute on function public.intel606_remove_member(uuid,integer) to authenticated;
notify pgrst,'reload schema';
commit;


-- 整合階段｜近距／遠距全員討論計時（Beta.2 最終邏輯）
-- 以下計時欄位與 RPC 已併入本份全新建置檔。
-- 新版不更動近距既有階段推進；計時到期僅提醒。
-- 不會清除任何房間、情報卡、角色或玩家紀錄。
begin;

alter table public.intel606_rooms
  add column if not exists near_timer_duration_seconds integer not null default 0,
  add column if not exists near_timer_round integer,
  add column if not exists near_timer_started_at timestamptz,
  add column if not exists near_timer_deadline_at timestamptz,
  add column if not exists near_timer_paused boolean not null default false,
  add column if not exists near_timer_remaining_seconds integer;

alter table public.intel606_rooms drop constraint if exists intel606_near_timer_duration_check;
alter table public.intel606_rooms add constraint intel606_near_timer_duration_check
  check (near_timer_duration_seconds between 0 and 3600 and near_timer_duration_seconds % 60 = 0);

-- 以既有已驗收的 room_state 為基礎，只新增公開計時欄位；不改動秘密身分或投票的存取條件。
create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_message_total integer := 0;
  v_vote_count integer := 0;
  v_vote_expected integer := 0;
  v_vote_mine boolean := false;
  v_vote_first_summary jsonb := '[]'::jsonb;
  v_vote_second_summary jsonb := '[]'::jsonb;
  v_guess_code text := null;
  v_identified_correct boolean := null;
  v_guess_correct boolean := null;
  v_winner text := null;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  -- 實際伺服器時鐘是唯一的截止依據。任何合法玩家讀取狀態時
  -- 都可觸發過期轉換，無須主控端保持連線；資料庫交易確保只執行一次。
  if v_room.play_mode='remote' and v_room.phase='chat'
     and v_room.discussion_mode='timed' and not v_room.chat_paused
     and v_room.chat_deadline_at is not null
     and clock_timestamp() >= v_room.chat_deadline_at then
    update public.intel606_rooms
      set phase='vote_pending', chat_deadline_at=null,chat_remaining_seconds=0,
          version=version+1,updated_at=now()
      where id=p_room and phase='chat' and not chat_paused
        and chat_deadline_at is not null and chat_deadline_at<=clock_timestamp();
    select * into v_room from public.intel606_rooms where id=p_room;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') or
       (v_room.play_mode='remote' and v_room.phase in ('reveal','guess')) then
      v_unmasked := v_secret.undercover_seat;
    end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode='remote' and v_room.phase='answer' then
    select guess_code into v_guess_code from intelligence_private.intel606_guesses
      where room_id=p_room and round_no=v_room.round_no;
    v_identified_correct := v_room.vote_result_type='identified'
      and v_room.vote_result_seat=v_secret.undercover_seat;
    v_guess_correct := v_guess_code is not null and v_guess_code=v_secret.secret_code;
    v_winner := case when v_identified_correct and not v_guess_correct then 'agents' else 'undercover' end;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', c.clue_text, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;

  if v_room.play_mode='remote' and v_room.phase in ('chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_message_total from intelligence_private.intel606_messages
      where room_id=p_room and round_no=v_room.round_no;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'seat',q.seat_no, 'text',q.message_text, 'sent_at',q.created_at
    ) order by q.id),'[]'::jsonb)
      into v_messages
    from (
      select id,seat_no,message_text,created_at
        from intelligence_private.intel606_messages
        where room_id=p_room and round_no=v_room.round_no
        order by id desc limit 100
    ) q;
  end if;
  if v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_vote_expected from public.intel606_members where room_id=p_room;
    if v_room.phase in ('vote_1','vote_2') then
      select count(*) into v_vote_count from intelligence_private.intel606_votes
        where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
      if v_member.user_id is not null then
        select exists(select 1 from intelligence_private.intel606_votes
          where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
            and user_id=auth.uid()) into v_vote_mine;
      end if;
    end if;
    -- 第一輪必須完成後才能公開統計；第二輪票數直到第二輪封存才可公開。
    if v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_first_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=1
              group by target_seat) s;
    end if;
    if v_room.phase in ('vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_second_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=2
              group by target_seat) s;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'host_plays',v_room.host_plays, 'host_mode',v_room.host_mode,
    'auto_phase_at',case when v_room.host_mode='auto' then v_room.auto_phase_at else null end,
    'discussion_seconds', v_room.discussion_seconds,
    'near_timer_seconds', case when v_room.play_mode='near' then v_room.near_timer_duration_seconds else 0 end,
    'near_timer_round', case when v_room.play_mode='near' then v_room.near_timer_round else null end,
    'near_timer_started_at', case when v_room.play_mode='near' and v_room.phase='discussion' then v_room.near_timer_started_at else null end,
    'near_timer_deadline_at', case when v_room.play_mode='near' and v_room.phase='discussion' then v_room.near_timer_deadline_at else null end,
    'near_timer_paused', (v_room.play_mode='near' and v_room.phase='discussion' and v_room.near_timer_paused),
    'near_timer_remaining_seconds', case when v_room.play_mode='near' and v_room.phase='discussion' then v_room.near_timer_remaining_seconds else null end,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'chat_messages', v_messages, 'chat_message_total', v_message_total,
    'chat_started_at', case when v_room.play_mode='remote' then v_room.chat_started_at else null end,
    'chat_deadline_at', case when v_room.play_mode='remote' then v_room.chat_deadline_at else null end,
    'chat_paused', (v_room.play_mode='remote' and v_room.chat_paused),
    'chat_remaining_seconds', case when v_room.play_mode='remote' then v_room.chat_remaining_seconds else null end
  ) || jsonb_build_object(
    'vote_round',case when v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then v_room.vote_round else 0 end,
    'vote_candidates',case when v_room.play_mode='remote' and v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then to_jsonb(v_room.vote_candidates) else null end,
    'vote_cast_count',v_vote_count, 'vote_expected_count',v_vote_expected, 'vote_my_submitted',v_vote_mine,
    'vote_first_summary',v_vote_first_summary,'vote_second_summary',v_vote_second_summary,
    'vote_result_type',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_type else null end,
    'vote_result_seat',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_seat else null end,
    'guess_status',case when v_room.play_mode='remote' and v_room.phase in ('reveal','guess','answer') then v_room.guess_status else null end,
    'guess_code',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_code else null end,
    'identified_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_identified_correct else null end,
    'guess_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_correct else null end,
    'winner',case when v_room.play_mode='remote' and v_room.phase='answer' then v_winner else null end,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  );
end;
$$;

-- 只有房主可設定及控制近距計時，時間到不自動揭曉。
create or replace function public.intel606_near_timer_control(p_room uuid,p_action text,p_seconds integer default 0)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_now timestamptz := clock_timestamp();
  v_rem integer;
begin
  if auth.uid() is null then raise exception '尚未取得登入身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if v_room.host_id<>auth.uid() then raise exception '只有主控可操作討論計時'; end if;
  if v_room.play_mode<>'near' then raise exception '此計時器只適用近距模式'; end if;
  if v_room.phase='closed' then raise exception '房間已結束'; end if;
  if p_action='configure' then
    if v_room.phase not in ('lobby','discussion') then raise exception '此階段不可更改討論時間'; end if;
    if p_seconds is null or p_seconds<0 or p_seconds>3600 or p_seconds%60<>0 then
      raise exception '討論時間只能設定0或1至60分鐘';
    end if;
    if v_room.phase='discussion' and v_room.near_timer_round=v_room.round_no
       and v_room.near_timer_started_at is not null then
      raise exception '請先重設目前倒數，再修改討論時間';
    end if;
    update public.intel606_rooms
      set near_timer_duration_seconds=p_seconds,near_timer_round=null,
          near_timer_started_at=null,near_timer_deadline_at=null,
          near_timer_paused=false,near_timer_remaining_seconds=null
      where id=p_room;
  elsif p_action='start' then
    if v_room.phase<>'discussion' then raise exception '請在現場討論階段開始計時'; end if;
    if v_room.near_timer_duration_seconds<60 then raise exception '請先設定討論分鐘數'; end if;
    if v_room.near_timer_round=v_room.round_no and v_room.near_timer_started_at is not null then
      raise exception '本輪計時已啟動；如需重來，請先重設';
    end if;
    update public.intel606_rooms
      set near_timer_round=round_no,near_timer_started_at=v_now,
          near_timer_deadline_at=v_now+make_interval(secs=>near_timer_duration_seconds),
          near_timer_remaining_seconds=near_timer_duration_seconds,near_timer_paused=false
      where id=p_room;
  elsif p_action='reset' then
    if v_room.phase<>'discussion' then raise exception '只有討論階段能重設計時'; end if;
    update public.intel606_rooms
      set near_timer_round=null,near_timer_started_at=null,near_timer_deadline_at=null,
          near_timer_remaining_seconds=null,near_timer_paused=false where id=p_room;
  elsif p_action in ('pause','resume','extend') then
    if v_room.phase<>'discussion' or v_room.near_timer_round is distinct from v_room.round_no
       or v_room.near_timer_started_at is null then raise exception '本輪倒數尚未開始'; end if;
    if p_action='pause' then
      if v_room.near_timer_paused then raise exception '倒數已暫停'; end if;
      v_rem:=greatest(0,ceil(extract(epoch from v_room.near_timer_deadline_at-v_now))::integer);
      update public.intel606_rooms set near_timer_paused=true,near_timer_deadline_at=null,
        near_timer_remaining_seconds=v_rem where id=p_room;
    elsif p_action='resume' then
      if not v_room.near_timer_paused then raise exception '倒數尚未暫停'; end if;
      update public.intel606_rooms set near_timer_paused=false,
        near_timer_deadline_at=v_now+make_interval(secs=>near_timer_remaining_seconds) where id=p_room;
    else
      if p_seconds not in (60,180) then raise exception '只允許延長1或3分鐘'; end if;
      v_rem:=case when v_room.near_timer_paused then coalesce(v_room.near_timer_remaining_seconds,0)
        else greatest(0,ceil(extract(epoch from v_room.near_timer_deadline_at-v_now))::integer) end;
      update public.intel606_rooms set
        near_timer_remaining_seconds=v_rem+p_seconds,
        near_timer_deadline_at=case when near_timer_paused then null else v_now+make_interval(secs=>v_rem+p_seconds) end
        where id=p_room;
    end if;
  else
    raise exception '無效的計時操作';
  end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;
revoke all on function public.intel606_near_timer_control(uuid,text,integer) from public,anon,authenticated;
grant execute on function public.intel606_near_timer_control(uuid,text,integer) to authenticated;
-- 維持資料庫10/30以後的明確授權。
revoke all on function public.intel606_room_state(uuid) from public,anon,authenticated;
grant execute on function public.intel606_room_state(uuid) to authenticated;
commit;

-- Additional v2.8.0 dual-remote module.
-- 606 情報局 v2.8.0 Beta：既有 v2.7.0 / v2.7.1 資料庫原地升級
-- 先備份；不要將舊版 full-new-project SQL 在現有專案重新執行。
-- 只修改遠距互動子模式與正式線索/討論 RPC；既有遊戲核心不變。
BEGIN;

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM public.intel606_rooms WHERE phase NOT IN ('lobby','closed')) THEN
    RAISE EXCEPTION 'v2.8.0 升級中止：有進行中的房間。請先結束或完成遊戲再升級。';
  END IF;
END $guard$;

ALTER TABLE public.intel606_rooms
  ADD COLUMN IF NOT EXISTS remote_interaction_mode text NOT NULL DEFAULT 'text';
ALTER TABLE public.intel606_rooms DROP CONSTRAINT IF EXISTS intel606_remote_interaction_mode_check;
ALTER TABLE public.intel606_rooms ADD CONSTRAINT intel606_remote_interaction_mode_check
  CHECK (remote_interaction_mode IN ('text','voice') AND
         (play_mode = 'remote' OR remote_interaction_mode = 'text'));

ALTER TABLE intelligence_private.intel606_clues
  ADD COLUMN IF NOT EXISTS delivery_method text NOT NULL DEFAULT 'text';
ALTER TABLE intelligence_private.intel606_clues
  DROP CONSTRAINT IF EXISTS intel606_clue_valid;
-- 將 Beta.2 原本使用的特殊字串清成純 metadata，不保留替代文字內容。
UPDATE intelligence_private.intel606_clues
  SET delivery_method='skipped'
  WHERE was_skipped=true AND delivery_method <> 'skipped';
UPDATE intelligence_private.intel606_clues
  SET clue_text=null, delivery_method='voice'
  WHERE was_skipped=false AND clue_text='🎙〔語音線索，未留文字稿〕';
ALTER TABLE intelligence_private.intel606_clues
  DROP CONSTRAINT IF EXISTS intel606_clues_delivery_method_check;
ALTER TABLE intelligence_private.intel606_clues
  ADD CONSTRAINT intel606_clues_delivery_method_check
    CHECK (delivery_method IN ('text','voice','skipped'));
ALTER TABLE intelligence_private.intel606_clues
  ADD CONSTRAINT intel606_clue_valid CHECK (
      (delivery_method='skipped' AND was_skipped=true AND clue_text IS NULL) OR
      (delivery_method='voice' AND was_skipped=false AND clue_text IS NULL) OR
      (delivery_method='text' AND was_skipped=false AND clue_text IS NOT NULL
        AND char_length(btrim(clue_text)) BETWEEN 1 AND 80)
  );

-- 舊版建立房間 RPC 保留（預設建立文字房間），新網站使用 v28 明確指定子模式。

create or replace function public.intel606_create_room_v28(
  p_size integer,p_play_mode text,p_discussion_mode text,p_discussion_seconds integer,
  p_host_plays boolean,p_host_name text,p_host_mode text,p_remote_interaction_mode text
)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room uuid;
  v_code text;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_i integer;
  v_try integer;
  v_name text := btrim(coalesce(p_host_name,''));
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if p_size not in (3,4) or p_size is null then raise exception '只支援3×3及4×4'; end if;
  if p_play_mode not in ('near','remote') or p_play_mode is null then raise exception '遊戲模式不正確'; end if;
  if p_discussion_mode not in ('manual','timed') or p_discussion_mode is null then raise exception '討論模式不正確'; end if;
  if p_discussion_seconds not in (180,300,480,600) or p_discussion_seconds is null then
    raise exception '討論時間只能選3、5、8或10分鐘';
  end if;
  if p_host_mode not in ('manual','auto') or p_host_mode is null then raise exception '主持方式不正確'; end if;
  if p_remote_interaction_mode not in ('text','voice') or p_remote_interaction_mode is null then
    raise exception '遠距互動模式必須為文字或語音';
  end if;
  if p_play_mode='near' then
    p_remote_interaction_mode:='text';
    p_host_mode:='manual';p_discussion_mode:='manual';p_discussion_seconds:=300;
  end if;
  if coalesce(p_host_plays,false) and (char_length(v_name)<1 or char_length(v_name)>24) then
    raise exception '主控兼玩家時，請填寫1～24字的代稱';
  end if;
  for v_try in 1..10 loop
    v_code:='';
    for v_i in 1..6 loop
      v_code:=v_code || substr(v_alphabet,intelligence_private.intel606_rand(length(v_alphabet))+1,1);
    end loop;
    begin
      insert into public.intel606_rooms
        (room_code,host_id,board_size,play_mode,discussion_mode,discussion_seconds,host_plays,host_mode,remote_interaction_mode)
      values (v_code,auth.uid(),p_size,p_play_mode,p_discussion_mode,p_discussion_seconds,
              coalesce(p_host_plays,false),p_host_mode,p_remote_interaction_mode)
      returning id into v_room;
      if coalesce(p_host_plays,false) then
        insert into public.intel606_members(room_id,user_id,seat_no,display_name)
          values(v_room,auth.uid(),1,v_name);
      end if;
      return public.intel606_room_state(v_room);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception '房間代碼產生失敗，請重新嘗試';
end;
$$;

create or replace function public.intel606_list_my_rooms()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rooms jsonb;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
     'room_id',r.id,'code',r.room_code,'phase',r.phase,'round',r.round_no,
     'size',r.board_size,'play_mode',r.play_mode,'remote_interaction_mode',r.remote_interaction_mode,'host_plays',r.host_plays,
     'host_mode',r.host_mode,'member_count',
       (select count(*) from public.intel606_members m where m.room_id=r.id),
     'updated_at',r.updated_at) order by r.updated_at desc),'[]'::jsonb)
    into v_rooms
  from (select * from public.intel606_rooms where host_id=auth.uid()
        order by updated_at desc limit 50) r;
  return v_rooms;
end;
$$;

create or replace function public.intel606_host_action(p_room uuid, p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_total integer; v_ready integer;
  v_codes text[] := '{}'::text[]; v_temp text; v_j integer; v_i integer; v_repeat integer;
  v_spy integer; v_first integer; v_second integer; v_offset integer;
  v_secret text; v_card uuid; v_snapshot jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found or v_room.host_id <> auth.uid() then raise exception '只有主控端可以執行此操作'; end if;
  select count(*),count(*) filter (where is_ready) into v_total,v_ready from public.intel606_members where room_id=p_room;
  if p_action = 'start' and v_room.phase = 'lobby' then
    if v_total < 3 or v_total > 8 then raise exception '需有 3～8 位玩家才能開始'; end if;
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    -- 3×3：九組代號各兩次，共18位置（6×3）。
    -- 4×4：十六組代號各三次，共48位置（8×6）。
    for v_i in 0..(v_room.board_size*v_room.board_size-1) loop
      for v_repeat in 1..(case when v_room.board_size = 3 then 2 else 3 end) loop
        v_codes := array_append(v_codes,
          substr('ABCD', (v_i % v_room.board_size)+1, 1) || ((v_i/v_room.board_size)+1)::text);
      end loop;
    end loop;
    for v_i in reverse array_length(v_codes,1)..2 loop
      v_j := intelligence_private.intel606_rand(v_i) + 1;
      v_temp := v_codes[v_i]; v_codes[v_i] := v_codes[v_j]; v_codes[v_j] := v_temp;
    end loop;
    v_spy := intelligence_private.intel606_rand(v_total) + 1;
    -- 下一輪如果編號不連續，不直接假設有 1..N，從實際成員隨機選。
    select seat_no into v_spy from public.intel606_members where room_id=p_room order by seat_no offset (v_spy-1) limit 1;
    insert into intelligence_private.intel606_secrets(room_id,undercover_seat,code_map)
      values(p_room,v_spy,to_jsonb(v_codes));
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='identity',current_card_id=null,current_card_snapshot=null,dice_rolled_at=null,clue_current_seat=null,clue_completed_at=null where id=p_room;
  elsif p_action = 'roll' and v_room.phase = 'identity' then
    if v_ready <> v_total then raise exception '請等所有玩家確認身分卡後再擲骰'; end if;
    if v_room.board_size = 3 then
      v_first := intelligence_private.intel606_rand(6) + 1;  -- 藍：1～6
      v_second := intelligence_private.intel606_rand(3) + 1; -- 紅：1/1/2/2/3/3
      v_offset := (v_first - 1) * 3 + (v_second - 1);
    else
      v_first := intelligence_private.intel606_rand(8) + 1;  -- 藍：1～8
      v_second := intelligence_private.intel606_rand(6) + 1; -- 紅：1～6，永不重擲
      v_offset := (v_first - 1) * 6 + (v_second - 1);
    end if;
    -- 以雙色骰子定位對照表的唯一位置，再由該位置讀取機密代號。
    select code_map->>v_offset into v_secret
      from intelligence_private.intel606_secrets where room_id=p_room;
    if v_secret is null then raise exception '代號對照表資料不完整，請建立新一輪任務'; end if;
    update intelligence_private.intel606_secrets
       set secret_code=v_secret,dice_first=v_first,dice_second=v_second
      where room_id=p_room;
    update public.intel606_rooms set phase='dossier',dice_rolled_at=clock_timestamp() where id=p_room;
  elsif p_action = 'draw' and v_room.phase = 'dossier' then
    select id into v_card from public.intel606_cards
       where owner_id=auth.uid() and board_size=v_room.board_size and active=true order by random() limit 1;
    if v_card is null then raise exception '沒有符合此宮格的啟用情報卡，請先建立'; end if;
    v_snapshot := intelligence_private.intel606_randomized_card(v_card);
    update public.intel606_rooms
       set phase = case when v_room.play_mode = 'remote' then 'clue' else 'discussion' end,
           current_card_id=v_card,current_card_snapshot=v_snapshot,
           clue_current_seat = case when v_room.play_mode='remote' then
             (select min(m.seat_no) from public.intel606_members m where m.room_id=p_room) else null end,
           clue_completed_at = null
      where id=p_room;
  elsif p_action = 'skip_clue' and v_room.play_mode = 'remote' and v_room.phase = 'clue' then
    if v_room.clue_current_seat is null or v_room.clue_completed_at is not null then
      raise exception '所有線索已完成，不能再跳過發言';
    end if;
    insert into intelligence_private.intel606_clues(room_id, round_no, seat_no, clue_text, was_skipped, delivery_method)
      values (p_room, v_room.round_no, v_room.clue_current_seat, null, true, 'skipped');
    update public.intel606_rooms
      set clue_current_seat=(select min(m.seat_no) from public.intel606_members m
             where m.room_id=p_room and m.seat_no>v_room.clue_current_seat),
          clue_completed_at=(case when exists(
            select 1 from public.intel606_members m where m.room_id=p_room and m.seat_no>v_room.clue_current_seat
          ) then null else clock_timestamp() end)
      where id=p_room;
  elsif p_action = 'unmask' and v_room.phase = 'discussion' then
    update public.intel606_rooms set phase='undercover' where id=p_room;
  elsif p_action = 'answer' and v_room.phase = 'undercover' then
    update public.intel606_rooms set phase='answer' where id=p_room;
  elsif p_action = 'next' and v_room.phase = 'answer' then
    delete from intelligence_private.intel606_secrets where room_id=p_room;
    update public.intel606_members set is_ready=false where room_id=p_room;
    update public.intel606_rooms set phase='lobby',round_no=round_no+1,current_card_id=null,current_card_snapshot=null,dice_rolled_at=null,clue_current_seat=null,clue_completed_at=null where id=p_room;
  elsif p_action = 'close' and v_room.phase <> 'closed' then
    update public.intel606_rooms set phase='closed' where id=p_room;
  else
    raise exception '目前階段不允許執行這個操作';
  end if;
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

create or replace function public.intel606_room_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_member public.intel606_members%rowtype;
  v_host boolean;
  v_people jsonb;
  v_card jsonb := null;
  v_role text := null;
  v_map jsonb := null;
  v_code text := null;
  v_unmasked integer := null;
  v_drawn_code text := null;
  v_die1 integer := null;
  v_die2 integer := null;
  v_position integer := null;
  v_answer_word text := null;
  v_clues jsonb := '[]'::jsonb;
  v_messages jsonb := '[]'::jsonb;
  v_message_total integer := 0;
  v_vote_count integer := 0;
  v_vote_expected integer := 0;
  v_vote_mine boolean := false;
  v_vote_first_summary jsonb := '[]'::jsonb;
  v_vote_second_summary jsonb := '[]'::jsonb;
  v_guess_code text := null;
  v_identified_correct boolean := null;
  v_guess_correct boolean := null;
  v_winner text := null;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found then raise exception '找不到房間'; end if;
  v_host := v_room.host_id = auth.uid();
  select * into v_member from public.intel606_members where room_id = p_room and user_id = auth.uid();
  if not v_host and v_member.user_id is null then raise exception '無權讀取此房間'; end if;

  -- 實際伺服器時鐘是唯一的截止依據。任何合法玩家讀取狀態時
  -- 都可觸發過期轉換，無須主控端保持連線；資料庫交易確保只執行一次。
  if v_room.play_mode='remote' and v_room.phase='chat'
     and v_room.discussion_mode='timed' and not v_room.chat_paused
     and v_room.chat_deadline_at is not null
     and clock_timestamp() >= v_room.chat_deadline_at then
    update public.intel606_rooms
      set phase='vote_pending', chat_deadline_at=null,chat_remaining_seconds=0,
          version=version+1,updated_at=now()
      where id=p_room and phase='chat' and not chat_paused
        and chat_deadline_at is not null and chat_deadline_at<=clock_timestamp();
    select * into v_room from public.intel606_rooms where id=p_room;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('seat', seat_no, 'name', display_name, 'ready', is_ready) order by seat_no),'[]'::jsonb)
    into v_people from public.intel606_members where room_id = p_room;
  if v_room.phase not in ('lobby','closed') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    if v_member.user_id is not null then
      if v_secret.undercover_seat = v_member.seat_no then
        v_role := 'undercover';
      else
        v_role := 'agent';
        v_map := v_secret.code_map;
        if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer')
          or (v_room.phase = 'dossier' and
              (v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds')) then
          v_code := v_secret.secret_code;
          v_drawn_code := v_secret.secret_code;
        end if;
      end if;
    end if;
    if v_room.phase in ('dossier','clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
      -- 開骰時刻由資料庫記錄；動畫的3秒內不送出最終骰值，避免動畫提前洩露結果。
      if v_room.dice_rolled_at is null or clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds' then
        v_die1 := v_secret.dice_first;
        v_die2 := v_secret.dice_second;
      end if;
    end if;
    if v_room.phase in ('undercover','answer') or
       (v_room.play_mode='remote' and v_room.phase in ('reveal','guess')) then
      v_unmasked := v_secret.undercover_seat;
    end if;
    if v_room.phase = 'answer' then
      v_code := v_secret.secret_code;
      v_drawn_code := v_secret.secret_code;
    end if;
  end if;
  if v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','discussion','undercover','answer') then
    v_card := v_room.current_card_snapshot;
  end if;
  if v_room.phase = 'answer' and v_card is not null and v_secret.secret_code is not null then
    -- 同一代號在對照表出現2或3次；但在情報卡上只能對應一格。
    -- 因此依代號 A1..C3 / A1..D4 定位，而不是使用 code_map 首次出現的位置。
    v_position := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
                + (substring(v_secret.secret_code from 2)::integer - 1) * v_room.board_size;
    if v_position between 0 and v_room.board_size*v_room.board_size - 1 then
      v_answer_word := v_card->'cells'->>v_position;
    end if;
  end if;
  if v_room.play_mode='remote' and v_room.phase='answer' then
    select guess_code into v_guess_code from intelligence_private.intel606_guesses
      where room_id=p_room and round_no=v_room.round_no;
    v_identified_correct := v_room.vote_result_type='identified'
      and v_room.vote_result_seat=v_secret.undercover_seat;
    v_guess_correct := v_guess_code is not null and v_guess_code=v_secret.secret_code;
    v_winner := case when v_identified_correct and not v_guess_correct then 'agents' else 'undercover' end;
  end if;
  if v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'seat', c.seat_no, 'text', case when c.delivery_method='text' then c.clue_text else null end,
      'method', c.delivery_method, 'skipped', c.was_skipped, 'submitted_at', c.created_at
    ) order by c.seat_no), '[]'::jsonb) into v_clues
    from intelligence_private.intel606_clues c
    where c.room_id = p_room and c.round_no = v_room.round_no;
  end if;

  if v_room.play_mode='remote' and v_room.phase in ('chat','vote_pending','vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_message_total from intelligence_private.intel606_messages
      where room_id=p_room and round_no=v_room.round_no;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'seat',q.seat_no, 'text',q.message_text, 'sent_at',q.created_at
    ) order by q.id),'[]'::jsonb)
      into v_messages
    from (
      select id,seat_no,message_text,created_at
        from intelligence_private.intel606_messages
        where room_id=p_room and round_no=v_room.round_no
        order by id desc limit 100
    ) q;
  end if;
  if v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then
    select count(*) into v_vote_expected from public.intel606_members where room_id=p_room;
    if v_room.phase in ('vote_1','vote_2') then
      select count(*) into v_vote_count from intelligence_private.intel606_votes
        where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round;
      if v_member.user_id is not null then
        select exists(select 1 from intelligence_private.intel606_votes
          where room_id=p_room and round_no=v_room.round_no and ballot_round=v_room.vote_round
            and user_id=auth.uid()) into v_vote_mine;
      end if;
    end if;
    -- 第一輪必須完成後才能公開統計；第二輪票數直到第二輪封存才可公開。
    if v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_first_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=1
              group by target_seat) s;
    end if;
    if v_room.phase in ('vote_result','reveal','guess','answer') then
      select coalesce(jsonb_agg(jsonb_build_object('seat',s.target_seat,'count',s.n) order by s.target_seat),'[]'::jsonb)
        into v_vote_second_summary
        from (select target_seat,count(*)::integer n from intelligence_private.intel606_votes
              where room_id=p_room and round_no=v_room.round_no and ballot_round=2
              group by target_seat) s;
    end if;
  end if;
  return jsonb_build_object(
    'room_id', v_room.id, 'code', v_room.room_code, 'phase', v_room.phase,
    'play_mode', v_room.play_mode, 'discussion_mode', v_room.discussion_mode,
    'host_plays',v_room.host_plays, 'host_mode',v_room.host_mode,
    'auto_phase_at',case when v_room.host_mode='auto' then v_room.auto_phase_at else null end,
    'discussion_seconds', v_room.discussion_seconds,
    'near_timer_seconds', case when v_room.play_mode='near' then v_room.near_timer_duration_seconds else 0 end,
    'near_timer_round', case when v_room.play_mode='near' then v_room.near_timer_round else null end,
    'near_timer_started_at', case when v_room.play_mode='near' and v_room.phase='discussion' then v_room.near_timer_started_at else null end,
    'near_timer_deadline_at', case when v_room.play_mode='near' and v_room.phase='discussion' then v_room.near_timer_deadline_at else null end,
    'near_timer_paused', (v_room.play_mode='near' and v_room.phase='discussion' and v_room.near_timer_paused),
    'near_timer_remaining_seconds', case when v_room.play_mode='near' and v_room.phase='discussion' then v_room.near_timer_remaining_seconds else null end,
    'clue_current_seat', case when v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') then v_room.clue_current_seat else null end,
    'clue_completed', (v_room.play_mode = 'remote' and v_room.phase in ('clue','chat','vote_pending','vote_1','vote_2','vote_result') and v_room.clue_completed_at is not null),
    'clues', v_clues,
    'chat_messages', v_messages, 'chat_message_total', v_message_total,
    'chat_started_at', case when v_room.play_mode='remote' then v_room.chat_started_at else null end,
    'chat_deadline_at', case when v_room.play_mode='remote' then v_room.chat_deadline_at else null end,
    'chat_paused', (v_room.play_mode='remote' and v_room.chat_paused),
    'chat_remaining_seconds', case when v_room.play_mode='remote' then v_room.chat_remaining_seconds else null end
  ) || jsonb_build_object(
    'vote_round',case when v_room.play_mode='remote' and v_room.phase in ('vote_1','vote_2','vote_result','reveal','guess','answer') then v_room.vote_round else 0 end,
    'vote_candidates',case when v_room.play_mode='remote' and v_room.phase in ('vote_2','vote_result','reveal','guess','answer') then to_jsonb(v_room.vote_candidates) else null end,
    'vote_cast_count',v_vote_count, 'vote_expected_count',v_vote_expected, 'vote_my_submitted',v_vote_mine,
    'vote_first_summary',v_vote_first_summary,'vote_second_summary',v_vote_second_summary,
    'vote_result_type',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_type else null end,
    'vote_result_seat',case when v_room.play_mode='remote' and v_room.phase in ('vote_result','reveal','guess','answer') then v_room.vote_result_seat else null end,
    'guess_status',case when v_room.play_mode='remote' and v_room.phase in ('reveal','guess','answer') then v_room.guess_status else null end,
    'guess_code',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_code else null end,
    'identified_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_identified_correct else null end,
    'guess_correct',case when v_room.play_mode='remote' and v_room.phase='answer' then v_guess_correct else null end,
    'winner',case when v_room.play_mode='remote' and v_room.phase='answer' then v_winner else null end,
    'round', v_room.round_no, 'size', v_room.board_size, 'version', v_room.version,
    'roll_started_at', v_room.dice_rolled_at, 'server_now', clock_timestamp(),
    'is_host', v_host, 'my_seat', v_member.seat_no, 'my_role', v_role,
    'members', v_people, 'code_map', v_map, 'secret_code', v_code,
    'undercover_seat', v_unmasked, 'card', v_card,
    'drawn_code', v_drawn_code, 'dice_first', v_die1, 'dice_second', v_die2,
    'answer_word', v_answer_word
  ) || jsonb_build_object(
    'remote_interaction_mode', v_room.remote_interaction_mode
  );
end;
$$;

-- 文字房間只能提交正式文字線索與文字自由討論。
create or replace function public.intel606_submit_clue(p_room uuid,p_text text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_seat integer;
  v_text text;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if v_room.play_mode <> 'remote' or v_room.phase <> 'clue' then
    raise exception '目前不是遠距正式發言階段';
  end if;
  if v_room.remote_interaction_mode <> 'text' then
    raise exception '此房間只接受語音線索，不可提交文字';
  end if;
  if v_room.clue_completed_at is not null or v_room.clue_current_seat is null then
    raise exception '本輪線索階段已完成';
  end if;
  select m.seat_no into v_seat from public.intel606_members m
    where m.room_id=p_room and m.user_id=auth.uid();
  if v_seat is null then raise exception '你不是這個房間的正式玩家'; end if;
  if v_seat <> v_room.clue_current_seat then raise exception '尚未輪到你的發言順序'; end if;
  v_text := btrim(coalesce(p_text,''));
  if v_text = '🎙〔語音線索，未留文字稿〕' then raise exception '不可使用舊版語音標記'; end if;
  if char_length(v_text)<1 or char_length(v_text)>80 then raise exception '線索請輸入1～80字'; end if;
  insert into intelligence_private.intel606_clues(room_id,round_no,seat_no,clue_text,was_skipped,delivery_method)
    values(p_room,v_room.round_no,v_seat,v_text,false,'text');
  update public.intel606_rooms
    set clue_current_seat=(select min(m.seat_no) from public.intel606_members m
      where m.room_id=p_room and m.seat_no>v_seat),
      clue_completed_at=(case when exists(
        select 1 from public.intel606_members m where m.room_id=p_room and m.seat_no>v_seat
      ) then null else clock_timestamp() end),
      version=version+1, updated_at=now()
    where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

create or replace function public.intel606_send_chat(p_room uuid,p_text text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_seat integer;
  v_text text;
  v_now timestamptz;
  v_last timestamptz;
  v_total integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if v_room.play_mode<>'remote' or v_room.phase<>'chat' then
    raise exception '目前尚未開放自由討論';
  end if;
  if v_room.remote_interaction_mode<>'text' then
    raise exception '純語音房間不開放文字遊戲討論';
  end if;
  select seat_no into v_seat from public.intel606_members
    where room_id=p_room and user_id=auth.uid();
  if v_seat is null then raise exception '只有本房間正式玩家能發送訊息'; end if;
  v_now := clock_timestamp();
  if v_room.discussion_mode='timed' then
    if v_room.chat_paused then raise exception '討論已暫停，暫時無法傳送訊息'; end if;
    if v_room.chat_deadline_at is null or v_now>=v_room.chat_deadline_at then
      -- 到期後無條件拒絕訊息；下次合法讀取狀態將推進至 vote_pending。
      raise exception '討論時間已結束，訊息未送出';
    end if;
  end if;
  v_text:=btrim(coalesce(p_text,''));
  if char_length(v_text)<1 or char_length(v_text)>200 then raise exception '討論訊息請輸入1～200字'; end if;
  select max(created_at) into v_last from intelligence_private.intel606_messages
    where room_id=p_room and round_no=v_room.round_no and user_id=auth.uid();
  if v_last is not null and v_now-v_last<interval '2 seconds' then
    raise exception '請稍候2秒再發送下一則訊息';
  end if;
  select count(*) into v_total from intelligence_private.intel606_messages
    where room_id=p_room and round_no=v_room.round_no;
  if v_total>=200 then raise exception '本輪討論已達200則訊息上限'; end if;
  insert into intelligence_private.intel606_messages(room_id,round_no,user_id,seat_no,message_text,created_at)
    values(p_room,v_room.round_no,auth.uid(),v_seat,v_text,v_now);
  update public.intel606_rooms set version=version+1,updated_at=now() where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

-- 語音房間僅記錄座位與發言完成時間，不保存口述內容。
create or replace function public.intel606_complete_voice_clue(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_seat integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id=p_room for update;
  if not found then raise exception '找不到房間'; end if;
  if v_room.play_mode <> 'remote' or v_room.remote_interaction_mode <> 'voice'
     or v_room.phase <> 'clue' then
    raise exception '此階段不允許登記語音線索';
  end if;
  if v_room.clue_completed_at is not null or v_room.clue_current_seat is null then
    raise exception '本輪線索已完成';
  end if;
  select m.seat_no into v_seat from public.intel606_members m
    where m.room_id=p_room and m.user_id=auth.uid();
  if v_seat is null then raise exception '只有本房間正式玩家能完成發言'; end if;
  if v_seat <> v_room.clue_current_seat then raise exception '尚未輪到你發言'; end if;
  -- Only completion metadata, never the audio itself or a transcribed placeholder.
  insert into intelligence_private.intel606_clues
    (room_id,round_no,seat_no,clue_text,was_skipped,delivery_method)
    values(p_room,v_room.round_no,v_seat,null,false,'voice');
  update public.intel606_rooms
    set clue_current_seat=(select min(m.seat_no) from public.intel606_members m
        where m.room_id=p_room and m.seat_no>v_seat),
        clue_completed_at=(case when exists(
          select 1 from public.intel606_members m where m.room_id=p_room and m.seat_no>v_seat
        ) then null else clock_timestamp() end),
        version=version+1,updated_at=now()
    where id=p_room;
  return public.intel606_room_state(p_room);
end;
$$;

REVOKE ALL ON FUNCTION public.intel606_create_room_v28(integer,text,text,integer,boolean,text,text,text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.intel606_complete_voice_clue(uuid) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.intel606_room_state(uuid) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.intel606_host_action(uuid,text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.intel606_list_my_rooms() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.intel606_submit_clue(uuid,text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.intel606_send_chat(uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_create_room_v28(integer,text,text,integer,boolean,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_complete_voice_clue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_room_state(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_host_action(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_list_my_rooms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_submit_clue(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.intel606_send_chat(uuid,text) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;

-- ============================ v2.9.0 近距課堂 ============================
-- ==============================================================================
-- 606 情報局 v2.9.0 Classroom｜從 v2.8.0 Stable 升級（新增「近距課堂」模式）
--
-- 適用：已在使用 v2.8.0 Stable / Beta / Beta.1 / Beta.2 的既有 Supabase 專案。
--       v2.7.x 專案請先執行 606-v2.7.1-to-v2.8.0-stable-upgrade.sql，再執行本檔。
--       全新空白專案請改用 606-intelligence-v2.9.0-classroom-full-new-project.sql。
--
-- 本檔只「新增」資料表、限制與 RPC，並以相容方式覆寫三個小型函式：
--   intel606_can_read_room（加入課堂學生與投影端的讀取權）
--   intel606_join_room    （拒絕以一般方式加入課堂房間，其餘行為與 v2.8.0 相同）
--   intel606_list_my_rooms（課堂房間顯示報到人數）
-- 不修改、不刪除任何既有房間、成員、情報卡或對局資料；可安全重複執行。
-- 單機、近距小組、遠距文字、遠距語音的 RPC 與 Edge Function 均不變。
--
-- 課堂模式資料流：
--   教師（房主）  → intel606_class_action / intel606_class_select / intel606_class_remove
--   學生          → intel606_class_join / intel606_class_flip
--   教室大螢幕    → intel606_class_display_join（需教師端產生的投影代碼）
--   三種裝置讀取  → intel606_class_state（依身分與階段過濾：臥底、投影端、教師端
--                   在結局前都拿不到機密代碼與正確詞語）
-- ==============================================================================

begin;

-- 1) 遊戲模式：新增 classroom。課堂模式固定 3×3。
alter table public.intel606_rooms drop constraint if exists intel606_rooms_play_mode_check;
alter table public.intel606_rooms add constraint intel606_rooms_play_mode_check
  check (play_mode in ('near','remote','classroom'));
alter table public.intel606_rooms drop constraint if exists intel606_rooms_classroom_size_check;
alter table public.intel606_rooms add constraint intel606_rooms_classroom_size_check
  check (play_mode <> 'classroom' or board_size = 3);

-- 2) 課堂專用資料表（全部放在 intelligence_private，前端無法直接讀寫）
create table if not exists intelligence_private.intel606_class_rooms (
  room_id uuid primary key references public.intel606_rooms(id) on delete cascade,
  display_token text not null check (char_length(display_token) between 20 and 64),
  show_join_qr boolean not null default false,
  discussion_step integer not null default 1 check (discussion_step between 1 and 3),
  accused_group integer check (accused_group between 1 and 6),
  guess_index integer check (guess_index between 0 and 8),
  result_type text check (result_type in ('wrong','tie','guess_right','guess_wrong')),
  identity_started_at timestamptz,
  card_public_at timestamptz
);

-- 全班報到名單：不受舊版「每房 8 人」座位限制；revealed_round 記錄本輪是否已翻牌。
create table if not exists intelligence_private.intel606_class_roster (
  room_id uuid not null references public.intel606_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 24),
  group_no integer not null check (group_no between 1 and 6),
  revealed_round integer not null default 0 check (revealed_round >= 0),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists intel606_class_roster_group_idx
  on intelligence_private.intel606_class_roster(room_id, group_no, joined_at);

-- 本輪六名玩家：每組恰好一人。下一輪保留，作為教師端的預選名單。
create table if not exists intelligence_private.intel606_class_players (
  room_id uuid not null references public.intel606_rooms(id) on delete cascade,
  group_no integer not null check (group_no between 1 and 6),
  user_id uuid not null,
  primary key (room_id, group_no),
  unique (room_id, user_id),
  foreign key (room_id, user_id)
    references intelligence_private.intel606_class_roster(room_id, user_id) on delete cascade
);

-- 教室大螢幕：以教師端提供的投影代碼登記，只能讀取公開資訊。
create table if not exists intelligence_private.intel606_class_displays (
  room_id uuid not null references public.intel606_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

revoke all on intelligence_private.intel606_class_rooms,
              intelligence_private.intel606_class_roster,
              intelligence_private.intel606_class_players,
              intelligence_private.intel606_class_displays
  from public, anon, authenticated;
alter table intelligence_private.intel606_class_rooms enable row level security;
alter table intelligence_private.intel606_class_roster enable row level security;
alter table intelligence_private.intel606_class_players enable row level security;
alter table intelligence_private.intel606_class_displays enable row level security;

-- 3) Realtime / REST 讀取權：課堂學生與投影端也能訂閱房間列的版本變化。
--    房間列本身不含身分或機密代碼；情報卡快照只在教師公開後才寫入。
create or replace function public.intel606_can_read_room(p_room uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.intel606_rooms r where r.id = p_room and r.host_id = auth.uid())
      or exists (select 1 from public.intel606_members m where m.room_id = p_room and m.user_id = auth.uid())
      or exists (select 1 from intelligence_private.intel606_class_roster c where c.room_id = p_room and c.user_id = auth.uid())
      or exists (select 1 from intelligence_private.intel606_class_displays d where d.room_id = p_room and d.user_id = auth.uid());
$$;
revoke all on function public.intel606_can_read_room(uuid) from public, anon, authenticated;
grant execute on function public.intel606_can_read_room(uuid) to authenticated;

-- 4) 舊版加入流程：與 v2.8.0 相同，只多一道課堂房間檢查。
create or replace function public.intel606_join_room(p_code text, p_name text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype; v_number integer; v_used integer[];
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if char_length(btrim(coalesce(p_name,''))) not between 1 and 24 then raise exception '暱稱需為 1～24 字'; end if;
  select * into v_room from public.intel606_rooms where room_code = upper(btrim(p_code)) for update;
  if not found then raise exception '查無此房間，請檢查代碼'; end if;
  if v_room.play_mode = 'classroom' then raise exception '這是課堂房間，請掃描老師提供的 QR Code 加入'; end if;
  if v_room.host_id = auth.uid() then raise exception '主控裝置不能以玩家身分加入自己的房間'; end if;
  if exists(select 1 from public.intel606_members where room_id=v_room.id and user_id=auth.uid()) then
    return public.intel606_room_state(v_room.id);
  end if;
  if v_room.phase <> 'lobby' then raise exception '遊戲已開始，暫時無法加入'; end if;
  select coalesce(array_agg(seat_no), '{}'::integer[]) into v_used from public.intel606_members where room_id=v_room.id;
  select g.seat into v_number from generate_series(1,8) as g(seat)
    where not (g.seat = any(v_used)) order by g.seat limit 1;
  if v_number is null then raise exception '房間已滿（最多 8 位）'; end if;
  insert into public.intel606_members(room_id,user_id,seat_no,display_name)
    values(v_room.id,auth.uid(),v_number,btrim(p_name));
  update public.intel606_rooms set version=version+1,updated_at=now() where id=v_room.id;
  return public.intel606_room_state(v_room.id);
end;
$$;
revoke all on function public.intel606_join_room(text,text) from public, anon, authenticated;
grant execute on function public.intel606_join_room(text,text) to authenticated;

-- 5) 我的房間：課堂房間以報到人數計算。
create or replace function public.intel606_list_my_rooms()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rooms jsonb;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
     'room_id',r.id,'code',r.room_code,'phase',r.phase,'round',r.round_no,
     'size',r.board_size,'play_mode',r.play_mode,'remote_interaction_mode',r.remote_interaction_mode,'host_plays',r.host_plays,
     'host_mode',r.host_mode,'member_count',
       case when r.play_mode = 'classroom'
         then (select count(*) from intelligence_private.intel606_class_roster c where c.room_id=r.id)
         else (select count(*) from public.intel606_members m where m.room_id=r.id) end,
     'updated_at',r.updated_at) order by r.updated_at desc),'[]'::jsonb)
    into v_rooms
  from (select * from public.intel606_rooms where host_id=auth.uid()
        order by updated_at desc limit 50) r;
  return v_rooms;
end;
$$;
revoke all on function public.intel606_list_my_rooms() from public, anon, authenticated;
grant execute on function public.intel606_list_my_rooms() to authenticated;

-- 6) 讀取課堂狀態：唯一的資料出口，依「教師／投影端／學生」與階段過濾。
create or replace function public.intel606_class_state(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_cfg intelligence_private.intel606_class_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_me intelligence_private.intel606_class_roster%rowtype;
  v_viewer text;
  v_active boolean;
  v_dice_ready boolean := false;
  v_total integer := 0;
  v_player_count integer := 0;
  v_players_flipped integer := 0;
  v_observers integer := 0;
  v_observers_flipped integer := 0;
  v_card jsonb := null;
  v_pos integer := null;
  v_word text := null;
  v_accused jsonb := null;
  v_undercover jsonb := null;
  v_result jsonb := null;
  v_my_group integer := null;
  v_my_flipped boolean := false;
  v_role text := null;
  v_code text := null;
  v_out jsonb;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room;
  if not found or v_room.play_mode <> 'classroom' then raise exception '找不到課堂房間'; end if;
  select * into v_cfg from intelligence_private.intel606_class_rooms where room_id = p_room;

  if v_room.host_id = auth.uid() then
    v_viewer := 'teacher';
  else
    select * into v_me from intelligence_private.intel606_class_roster
      where room_id = p_room and user_id = auth.uid();
    if found then v_viewer := 'student';
    elsif exists(select 1 from intelligence_private.intel606_class_displays
                 where room_id = p_room and user_id = auth.uid()) then v_viewer := 'display';
    else raise exception '無權讀取此房間';
    end if;
  end if;

  v_active := v_room.phase in ('identity','dossier','discussion','guess','answer');
  if v_active then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room;
    -- 骰子動畫 3 秒內不送出最終點數與代碼，避免動畫提前洩露結果（沿用 v2.5.5 規則）。
    v_dice_ready := v_room.dice_rolled_at is not null and v_secret.dice_first is not null
                    and clock_timestamp() >= v_room.dice_rolled_at + interval '3 seconds';
    if v_secret.secret_code is not null then
      v_pos := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
             + (substring(v_secret.secret_code from 2)::integer - 1) * 3;
    end if;
  end if;

  select count(*) into v_total from intelligence_private.intel606_class_roster where room_id = p_room;
  select count(*), count(*) filter (where v_active and r.revealed_round = v_room.round_no)
    into v_player_count, v_players_flipped
    from intelligence_private.intel606_class_players p
    join intelligence_private.intel606_class_roster r on r.room_id = p.room_id and r.user_id = p.user_id
    where p.room_id = p_room;
  select count(*), count(*) filter (where v_active and r.revealed_round = v_room.round_no)
    into v_observers, v_observers_flipped
    from intelligence_private.intel606_class_roster r
    where r.room_id = p_room
      and not exists (select 1 from intelligence_private.intel606_class_players p
                      where p.room_id = r.room_id and p.user_id = r.user_id);

  if v_room.phase in ('discussion','guess','answer') then
    v_card := v_room.current_card_snapshot;
  end if;

  -- 被指認者：猜詞階段只公開「被正確指認的臥底」；結局再公開全部。
  if v_room.phase in ('guess','answer') and v_cfg.accused_group is not null then
    select jsonb_build_object('group', p.group_no, 'name', r.display_name) into v_accused
      from intelligence_private.intel606_class_players p
      join intelligence_private.intel606_class_roster r on r.room_id = p.room_id and r.user_id = p.user_id
      where p.room_id = p_room and p.group_no = v_cfg.accused_group;
    if v_accused is null then v_accused := jsonb_build_object('group', v_cfg.accused_group, 'name', null); end if;
  end if;
  if v_room.phase = 'answer' then
    select jsonb_build_object('group', p.group_no, 'name', r.display_name) into v_undercover
      from intelligence_private.intel606_class_players p
      join intelligence_private.intel606_class_roster r on r.room_id = p.room_id and r.user_id = p.user_id
      where p.room_id = p_room and p.group_no = v_secret.undercover_seat;
    if v_undercover is null then v_undercover := jsonb_build_object('group', v_secret.undercover_seat, 'name', null); end if;
    if v_card is not null and v_pos between 0 and 8 then v_word := v_card->'cells'->>v_pos; end if;
    v_result := jsonb_build_object(
      'type', v_cfg.result_type,
      'winner', case when v_cfg.result_type = 'guess_wrong' then 'agents' else 'undercover' end,
      'undercover', v_undercover,
      'accused', v_accused,
      'code', v_secret.secret_code,
      'word', v_word,
      'guess_index', v_cfg.guess_index,
      'guess_word', case when v_cfg.guess_index is not null and v_card is not null
                         then v_card->'cells'->>v_cfg.guess_index else null end
    );
  end if;

  v_out := jsonb_build_object(
    'room_id', v_room.id, 'phase', v_room.phase, 'play_mode', v_room.play_mode,
    'round', v_room.round_no, 'version', v_room.version, 'size', 3,
    'viewer', v_viewer, 'server_now', clock_timestamp(),
    'student_count', v_total, 'player_count', v_player_count, 'players_flipped', v_players_flipped,
    'observer_count', v_observers, 'observers_flipped', v_observers_flipped,
    'identity_started_at', case when v_active then v_cfg.identity_started_at else null end,
    'dice_rolled', v_active and v_room.dice_rolled_at is not null,
    'roll_started_at', case when v_active then v_room.dice_rolled_at else null end,
    'dice_first', case when v_dice_ready then v_secret.dice_first else null end,
    'dice_second', case when v_dice_ready then v_secret.dice_second else null end,
    'dice_ready', v_dice_ready,
    'card', v_card,
    'discussion_step', coalesce(v_cfg.discussion_step, 1),
    'accused', v_accused,
    'result', v_result
  );

  if v_viewer = 'teacher' then
    v_out := v_out || jsonb_build_object(
      'code', v_room.room_code,
      'display_token', v_cfg.display_token,
      'show_join_qr', coalesce(v_cfg.show_join_qr, false),
      'roster', coalesce((select jsonb_agg(jsonb_build_object(
          'id', r.user_id, 'name', r.display_name, 'group', r.group_no,
          'flipped', v_active and r.revealed_round = v_room.round_no
        ) order by r.group_no, r.joined_at)
        from intelligence_private.intel606_class_roster r where r.room_id = p_room), '[]'::jsonb),
      'players', coalesce((select jsonb_agg(jsonb_build_object(
          'group', p.group_no, 'id', p.user_id, 'name', r.display_name,
          'flipped', v_active and r.revealed_round = v_room.round_no
        ) order by p.group_no)
        from intelligence_private.intel606_class_players p
        join intelligence_private.intel606_class_roster r on r.room_id = p.room_id and r.user_id = p.user_id
        where p.room_id = p_room), '[]'::jsonb)
    );
  elsif v_viewer = 'display' then
    v_out := v_out || jsonb_build_object(
      'show_join_qr', v_room.phase = 'lobby' and coalesce(v_cfg.show_join_qr, false),
      'code', case when v_room.phase = 'lobby' and coalesce(v_cfg.show_join_qr, false) then v_room.room_code else null end
    );
  else
    select p.group_no into v_my_group from intelligence_private.intel606_class_players p
      where p.room_id = p_room and p.user_id = auth.uid();
    v_my_flipped := v_active and v_me.revealed_round = v_room.round_no;
    -- 只有翻牌後（或結局時）才回傳自己的身分；永遠不回傳其他學生的身分。
    if v_active and (v_my_flipped or v_room.phase = 'answer') then
      v_role := case
        when v_my_group is null then 'observer'
        when v_my_group = v_secret.undercover_seat then 'undercover'
        else 'agent' end;
      -- 情報員與局內人：擲骰動畫結束後取得同一個代碼；臥底在結局前永遠拿不到。
      if v_role in ('agent','observer') and v_dice_ready then v_code := v_secret.secret_code; end if;
      if v_room.phase = 'answer' then v_code := v_secret.secret_code; end if;
    end if;
    v_out := v_out || jsonb_build_object(
      'me', jsonb_build_object(
        'name', v_me.display_name, 'group', v_me.group_no,
        'is_player', v_active and v_my_group is not null,
        'flipped', v_my_flipped, 'role', v_role, 'code', v_code)
    );
  end if;
  return v_out;
end;
$$;

-- 7) 教師建立課堂房間（固定 3×3，近距、手動主持）。
create or replace function public.intel606_create_classroom_room()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room uuid; v_code text; v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_token text; v_i integer; v_try integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  for v_try in 1..10 loop
    v_code := '';
    for v_i in 1..6 loop
      v_code := v_code || substr(v_alphabet, intelligence_private.intel606_rand(length(v_alphabet))+1, 1);
    end loop;
    begin
      insert into public.intel606_rooms(room_code,host_id,board_size,play_mode,discussion_mode,discussion_seconds,host_plays,host_mode,remote_interaction_mode)
        values (v_code,auth.uid(),3,'classroom','manual',300,false,'manual','text')
        returning id into v_room;
      v_token := replace(gen_random_uuid()::text,'-','') || substr(replace(gen_random_uuid()::text,'-',''),1,8);
      insert into intelligence_private.intel606_class_rooms(room_id, display_token) values (v_room, v_token);
      return public.intel606_class_state(v_room);
    exception when unique_violation then null;
    end;
  end loop;
  raise exception '房間代碼產生失敗，請重新嘗試';
end;
$$;

-- 8) 學生掃碼報到：姓名＋組別。重整／重連沿用同一筆紀錄，不重複計數、不重抽身分。
create or replace function public.intel606_class_join(p_code text, p_name text, p_group integer)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_me intelligence_private.intel606_class_roster%rowtype;
  v_name text := btrim(coalesce(p_name,''));
  v_is_player boolean;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  if char_length(v_name) not between 1 and 24 then raise exception '姓名需為 1～24 字'; end if;
  if p_group is null or p_group not between 1 and 6 then raise exception '請選擇第 1～6 組'; end if;
  select * into v_room from public.intel606_rooms where room_code = upper(btrim(coalesce(p_code,''))) for update;
  if not found or v_room.play_mode <> 'classroom' then raise exception '查無此課堂任務，請重新掃描老師的 QR Code'; end if;
  if v_room.phase = 'closed' then raise exception '本堂課的情報任務已結束'; end if;
  if v_room.host_id = auth.uid() then raise exception '教師控制平板不能以學生身分報到'; end if;
  select * into v_me from intelligence_private.intel606_class_roster where room_id = v_room.id and user_id = auth.uid();
  if found then
    v_is_player := exists(select 1 from intelligence_private.intel606_class_players
                          where room_id = v_room.id and user_id = auth.uid());
    -- 本輪進行中的玩家不可改組，避免改變六組名單；其他情況可更正姓名與組別。
    if v_room.phase = 'lobby' or not v_is_player then
      if v_me.display_name is distinct from v_name or v_me.group_no is distinct from p_group then
        if v_me.group_no is distinct from p_group then
          delete from intelligence_private.intel606_class_players where room_id = v_room.id and user_id = auth.uid();
        end if;
        update intelligence_private.intel606_class_roster set display_name = v_name, group_no = p_group
          where room_id = v_room.id and user_id = auth.uid();
        update public.intel606_rooms set version = version+1, updated_at = now() where id = v_room.id;
      end if;
    end if;
    return public.intel606_class_state(v_room.id);
  end if;
  if (select count(*) from intelligence_private.intel606_class_roster where room_id = v_room.id) >= 60 then
    raise exception '本課堂報到人數已達上限（60 人）';
  end if;
  insert into intelligence_private.intel606_class_roster(room_id, user_id, display_name, group_no)
    values (v_room.id, auth.uid(), v_name, p_group);
  update public.intel606_rooms set version = version+1, updated_at = now() where id = v_room.id;
  return public.intel606_class_state(v_room.id);
end;
$$;

-- 9) 教室大螢幕登記：需教師端提供的投影代碼。
create or replace function public.intel606_class_display_join(p_code text, p_token text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype; v_cfg intelligence_private.intel606_class_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where room_code = upper(btrim(coalesce(p_code,'')));
  if not found or v_room.play_mode <> 'classroom' then raise exception '查無此課堂任務'; end if;
  select * into v_cfg from intelligence_private.intel606_class_rooms where room_id = v_room.id;
  if v_cfg.display_token is null or v_cfg.display_token <> coalesce(p_token,'') then
    raise exception '投影連結無效，請從教師控制平板重新開啟';
  end if;
  if v_room.host_id = auth.uid() then return public.intel606_class_state(v_room.id); end if;
  if exists(select 1 from intelligence_private.intel606_class_roster where room_id = v_room.id and user_id = auth.uid()) then
    raise exception '學生平板不能開啟投影畫面';
  end if;
  if (select count(*) from intelligence_private.intel606_class_displays where room_id = v_room.id) >= 20 then
    raise exception '投影裝置數量已達上限';
  end if;
  insert into intelligence_private.intel606_class_displays(room_id, user_id) values (v_room.id, auth.uid())
    on conflict do nothing;
  return public.intel606_class_state(v_room.id);
end;
$$;

-- 10) 學生翻牌（翻牌即確認）。重複點擊或重整不會重複計數。
create or replace function public.intel606_class_flip(p_room uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room for update;
  if not found or v_room.play_mode <> 'classroom' then raise exception '找不到課堂房間'; end if;
  if v_room.phase not in ('identity','dossier','discussion','guess','answer') then
    raise exception '老師尚未啟動身分認證';
  end if;
  update intelligence_private.intel606_class_roster set revealed_round = v_room.round_no
    where room_id = p_room and user_id = auth.uid() and revealed_round <> v_room.round_no;
  if found and exists(select 1 from intelligence_private.intel606_class_players
                      where room_id = p_room and user_id = auth.uid()) then
    -- 只有六名玩家的翻牌會推送版本，讓教師端即時更新「玩家已翻牌 n／6」。
    update public.intel606_rooms set version = version+1, updated_at = now() where id = p_room;
  elsif not found and not exists(select 1 from intelligence_private.intel606_class_roster
                                 where room_id = p_room and user_id = auth.uid()) then
    raise exception '你尚未在本課堂報到';
  end if;
  return public.intel606_class_state(p_room);
end;
$$;

-- 11) 教師指定／取消某組玩家（只限報到階段，啟動前可改選）。
create or replace function public.intel606_class_select(p_room uuid, p_group integer, p_user uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room for update;
  if not found or v_room.host_id <> auth.uid() or v_room.play_mode <> 'classroom' then
    raise exception '只有本課堂的教師可以選擇玩家';
  end if;
  if v_room.phase <> 'lobby' then raise exception '身分認證已啟動，請在下一輪再更換玩家'; end if;
  if p_group is null or p_group not between 1 and 6 then raise exception '組別不正確'; end if;
  if p_user is null then
    delete from intelligence_private.intel606_class_players where room_id = p_room and group_no = p_group;
  else
    if not exists(select 1 from intelligence_private.intel606_class_roster
                  where room_id = p_room and user_id = p_user and group_no = p_group) then
      raise exception '這位學生不在第 % 組的報到名單中', p_group;
    end if;
    delete from intelligence_private.intel606_class_players where room_id = p_room and user_id = p_user and group_no <> p_group;
    insert into intelligence_private.intel606_class_players(room_id, group_no, user_id) values (p_room, p_group, p_user)
      on conflict (room_id, group_no) do update set user_id = excluded.user_id;
  end if;
  update public.intel606_rooms set version = version+1, updated_at = now() where id = p_room;
  return public.intel606_class_state(p_room);
end;
$$;

-- 12) 教師移除誤報到的名單（只限報到階段）。
create or replace function public.intel606_class_remove(p_room uuid, p_user uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_room public.intel606_rooms%rowtype;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room for update;
  if not found or v_room.host_id <> auth.uid() or v_room.play_mode <> 'classroom' then
    raise exception '只有本課堂的教師可以管理名單';
  end if;
  if v_room.phase <> 'lobby' then raise exception '本輪進行中不能移除名單，請在下一輪報到階段操作'; end if;
  delete from intelligence_private.intel606_class_roster where room_id = p_room and user_id = p_user;
  if not found then raise exception '找不到這位學生'; end if;
  update public.intel606_rooms set version = version+1, updated_at = now() where id = p_room;
  return public.intel606_class_state(p_room);
end;
$$;

-- 13) 教師推進遊戲：所有抽籤、擲骰、查表、判定都在資料庫完成。
create or replace function public.intel606_class_action(p_room uuid, p_action text, p_arg integer default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_room public.intel606_rooms%rowtype;
  v_cfg intelligence_private.intel606_class_rooms%rowtype;
  v_secret intelligence_private.intel606_secrets%rowtype;
  v_players integer; v_groups integer; v_flipped integer;
  v_codes text[] := '{}'::text[]; v_temp text; v_i integer; v_j integer; v_repeat integer;
  v_first integer; v_second integer; v_code text; v_card uuid; v_pos integer;
begin
  if auth.uid() is null then raise exception '請先登入連線身分'; end if;
  select * into v_room from public.intel606_rooms where id = p_room for update;
  if not found or v_room.host_id <> auth.uid() or v_room.play_mode <> 'classroom' then
    raise exception '只有本課堂的教師可以執行此操作';
  end if;
  select * into v_cfg from intelligence_private.intel606_class_rooms where room_id = p_room for update;
  if not found then raise exception '課堂設定資料不完整，請重新建立房間'; end if;
  if v_room.phase in ('identity','dossier','discussion','guess','answer') then
    select * into v_secret from intelligence_private.intel606_secrets where room_id = p_room for update;
  end if;

  if p_action = 'start' and v_room.phase = 'lobby' then
    select count(*), count(distinct p.group_no) into v_players, v_groups
      from intelligence_private.intel606_class_players p
      join intelligence_private.intel606_class_roster r
        on r.room_id = p.room_id and r.user_id = p.user_id and r.group_no = p.group_no
      where p.room_id = p_room;
    if v_players <> 6 or v_groups <> 6 then raise exception '第 1～6 組都要各選一名玩家，才能啟動身分認證'; end if;
    if not exists(select 1 from public.intel606_cards where owner_id = auth.uid() and board_size = 3 and active) then
      raise exception '請先在情報卡資料庫建立至少一張啟用的 3×3 情報卡';
    end if;
    -- 沿用既有 3×3 對照表：九組代號各兩次，共 18 格（藍 1～6 列 × 紅 1～3 欄）。
    for v_i in 0..8 loop
      for v_repeat in 1..2 loop
        v_codes := array_append(v_codes, substr('ABC', (v_i % 3)+1, 1) || ((v_i/3)+1)::text);
      end loop;
    end loop;
    for v_i in reverse array_length(v_codes,1)..2 loop
      v_j := intelligence_private.intel606_rand(v_i) + 1;
      v_temp := v_codes[v_i]; v_codes[v_i] := v_codes[v_j]; v_codes[v_j] := v_temp;
    end loop;
    delete from intelligence_private.intel606_secrets where room_id = p_room;
    -- 六名玩家中隨機一名為臥底；以組別編號記錄。
    insert into intelligence_private.intel606_secrets(room_id, undercover_seat, code_map)
      values (p_room, intelligence_private.intel606_rand(6) + 1, to_jsonb(v_codes));
    update intelligence_private.intel606_class_rooms
      set discussion_step = 1, accused_group = null, guess_index = null, result_type = null,
          identity_started_at = clock_timestamp(), card_public_at = null
      where room_id = p_room;
    update public.intel606_rooms
      set phase = 'identity', current_card_id = null, current_card_snapshot = null, dice_rolled_at = null
      where id = p_room;

  elsif p_action = 'dice_stage' and v_room.phase = 'identity' then
    select count(*) into v_flipped
      from intelligence_private.intel606_class_players p
      join intelligence_private.intel606_class_roster r on r.room_id = p.room_id and r.user_id = p.user_id
      where p.room_id = p_room and r.revealed_round = v_room.round_no;
    if v_flipped < 6 then raise exception '六名玩家都翻牌後才能擲骰（目前 %／6）', v_flipped; end if;
    update public.intel606_rooms set phase = 'dossier' where id = p_room;

  elsif p_action = 'roll' and v_room.phase = 'dossier' then
    if v_room.dice_rolled_at is not null then raise exception '本輪已擲骰，同一輪只能擲一次'; end if;
    v_first := intelligence_private.intel606_rand(6) + 1;   -- 藍：1～6 各一面
    v_second := intelligence_private.intel606_rand(3) + 1;  -- 紅：1、1、2、2、3、3
    select v_secret.code_map->>((v_first - 1) * 3 + (v_second - 1)) into v_code;
    if v_code is null then raise exception '代號對照表資料不完整，請取消本輪後重新開始'; end if;
    update intelligence_private.intel606_secrets
      set secret_code = v_code, dice_first = v_first, dice_second = v_second
      where room_id = p_room;
    update public.intel606_rooms set dice_rolled_at = clock_timestamp() where id = p_room;

  elsif p_action = 'reveal_card' and v_room.phase = 'dossier' then
    if v_room.dice_rolled_at is null or v_secret.secret_code is null then raise exception '請先擲骰'; end if;
    if clock_timestamp() < v_room.dice_rolled_at + interval '3 seconds' then
      raise exception '骰子動畫尚未結束，請稍候再公開情報卡';
    end if;
    select id into v_card from public.intel606_cards
      where owner_id = auth.uid() and board_size = 3 and active order by random() limit 1;
    if v_card is null then raise exception '沒有啟用的 3×3 情報卡，請先建立'; end if;
    update public.intel606_rooms
      set phase = 'discussion', current_card_id = v_card,
          current_card_snapshot = intelligence_private.intel606_randomized_card(v_card)
      where id = p_room;
    update intelligence_private.intel606_class_rooms set card_public_at = clock_timestamp(), discussion_step = 1
      where room_id = p_room;

  elsif p_action = 'step' and v_room.phase = 'discussion' then
    if p_arg is null or p_arg not between 1 and 3 then raise exception '進度只能是 1～3'; end if;
    update intelligence_private.intel606_class_rooms set discussion_step = p_arg where room_id = p_room;

  elsif p_action = 'accuse' and v_room.phase = 'discussion' then
    if p_arg is null or not exists(select 1 from intelligence_private.intel606_class_players
                                   where room_id = p_room and group_no = p_arg) then
      raise exception '請選擇本輪六名玩家之一';
    end if;
    if p_arg = v_secret.undercover_seat then
      update intelligence_private.intel606_class_rooms set accused_group = p_arg where room_id = p_room;
      update public.intel606_rooms set phase = 'guess' where id = p_room;
    else
      update intelligence_private.intel606_class_rooms set accused_group = p_arg, result_type = 'wrong'
        where room_id = p_room;
      update public.intel606_rooms set phase = 'answer' where id = p_room;
    end if;

  elsif p_action = 'tie' and v_room.phase = 'discussion' then
    update intelligence_private.intel606_class_rooms set accused_group = null, result_type = 'tie'
      where room_id = p_room;
    update public.intel606_rooms set phase = 'answer' where id = p_room;

  elsif p_action = 'guess' and v_room.phase = 'guess' then
    if p_arg is null or p_arg not between 0 and 8 then raise exception '請點選九個詞語之一'; end if;
    v_pos := (ascii(left(v_secret.secret_code,1)) - ascii('A'))
           + (substring(v_secret.secret_code from 2)::integer - 1) * 3;
    update intelligence_private.intel606_class_rooms
      set guess_index = p_arg, result_type = case when p_arg = v_pos then 'guess_right' else 'guess_wrong' end
      where room_id = p_room;
    update public.intel606_rooms set phase = 'answer' where id = p_room;

  elsif (p_action = 'next' and v_room.phase = 'answer')
     or (p_action = 'abort' and v_room.phase in ('identity','dossier','discussion','guess')) then
    -- 保留報到名單與六組預選；輪次 +1，使上一輪翻牌、骰點、代碼、公開卡與結局全部失效。
    delete from intelligence_private.intel606_secrets where room_id = p_room;
    update intelligence_private.intel606_class_rooms
      set discussion_step = 1, accused_group = null, guess_index = null, result_type = null,
          identity_started_at = null, card_public_at = null
      where room_id = p_room;
    update public.intel606_rooms
      set phase = 'lobby', round_no = round_no + 1, current_card_id = null,
          current_card_snapshot = null, dice_rolled_at = null
      where id = p_room;

  elsif p_action = 'qr' and v_room.phase <> 'closed' then
    update intelligence_private.intel606_class_rooms set show_join_qr = coalesce(p_arg,0) = 1 where room_id = p_room;

  elsif p_action = 'close' and v_room.phase <> 'closed' then
    update public.intel606_rooms set phase = 'closed' where id = p_room;

  else
    raise exception '目前階段不允許執行這個操作';
  end if;
  update public.intel606_rooms set version = version+1, updated_at = now() where id = p_room;
  return public.intel606_class_state(p_room);
end;
$$;

revoke all on function public.intel606_class_state(uuid) from public, anon, authenticated;
revoke all on function public.intel606_create_classroom_room() from public, anon, authenticated;
revoke all on function public.intel606_class_join(text,text,integer) from public, anon, authenticated;
revoke all on function public.intel606_class_display_join(text,text) from public, anon, authenticated;
revoke all on function public.intel606_class_flip(uuid) from public, anon, authenticated;
revoke all on function public.intel606_class_select(uuid,integer,uuid) from public, anon, authenticated;
revoke all on function public.intel606_class_remove(uuid,uuid) from public, anon, authenticated;
revoke all on function public.intel606_class_action(uuid,text,integer) from public, anon, authenticated;
grant execute on function public.intel606_class_state(uuid) to authenticated;
grant execute on function public.intel606_create_classroom_room() to authenticated;
grant execute on function public.intel606_class_join(text,text,integer) to authenticated;
grant execute on function public.intel606_class_display_join(text,text) to authenticated;
grant execute on function public.intel606_class_flip(uuid) to authenticated;
grant execute on function public.intel606_class_select(uuid,integer,uuid) to authenticated;
grant execute on function public.intel606_class_remove(uuid,uuid) to authenticated;
grant execute on function public.intel606_class_action(uuid,text,integer) to authenticated;

notify pgrst, 'reload schema';
commit;

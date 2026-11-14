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

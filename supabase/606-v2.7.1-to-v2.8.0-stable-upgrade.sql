-- ==============================================================================
-- 606 情報局 v2.8.0 Stable｜從 v2.7.0 / v2.7.1 升級至 v2.8.0
-- 此檔與 v2.8.0 Beta 升級 SQL 具相同可執行內容，僅更新版本說明。
-- 【只用於舊版專案】已經是 v2.8.0 Beta/ Beta.1 / Beta.2 的資料庫不需執行。
-- 執行前備份，並確認所有對局已結束（SQL 自帶進行中房間檢查）。
-- 禁止拿 full-new-project SQL 重新套用到既有資料庫。
-- ==============================================================================

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

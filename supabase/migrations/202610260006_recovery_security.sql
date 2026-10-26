-- Milestone 5: reconnect heartbeat, disconnected-host handover, and action limits.
-- All counters and presence timestamps stay private to the database.
create table if not exists public.game_action_counters (
 user_id uuid not null references auth.users(id) on delete cascade,
 action_name text not null,
 scope_key text not null,
 window_started_at timestamptz not null,
 action_count integer not null default 0 check(action_count>=0),
 primary key(user_id,action_name,scope_key)
);
create index if not exists game_action_counters_window_idx on public.game_action_counters(window_started_at);
alter table public.game_action_counters enable row level security;
revoke all on public.game_action_counters from public,anon,authenticated;
drop policy if exists "Room members can read room" on public.game_rooms;
create policy "Unexpired room members can read room" on public.game_rooms for select to authenticated using (public.is_game_room_member(id) and expires_at>now());
drop policy if exists "Room members can read roster" on public.game_players;
create policy "Unexpired room members can read roster" on public.game_players for select to authenticated using (public.is_game_room_member(room_id) and exists(select 1 from public.game_rooms r where r.id=room_id and r.expires_at>now()));
drop policy if exists "Room members can read round chat" on public.game_messages;
create policy "Unexpired room members can read round chat" on public.game_messages for select to authenticated using (public.is_game_room_member(room_id) and exists(select 1 from public.game_rooms r where r.id=room_id and r.expires_at>now()));

create or replace function public.consume_game_action(p_room_id uuid,p_action text,p_limit integer,p_window_seconds integer)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_scope text:=coalesce(p_room_id::text,'global'); v_count integer;
begin
 if auth.uid() is null then raise exception 'Sign in as a guest first'; end if;
 if p_limit<1 or p_window_seconds<1 then raise exception 'Invalid action limit'; end if;
 perform pg_advisory_xact_lock(hashtext(auth.uid()::text),hashtext(p_action||':'||v_scope));
 insert into public.game_action_counters as c(user_id,action_name,scope_key,window_started_at,action_count)
 values(auth.uid(),p_action,v_scope,now(),1)
 on conflict(user_id,action_name,scope_key) do update set
  window_started_at=case when c.window_started_at<=now()-make_interval(secs=>p_window_seconds) then now() else c.window_started_at end,
  action_count=case when c.window_started_at<=now()-make_interval(secs=>p_window_seconds) then 1 else c.action_count+1 end
 returning action_count into v_count;
 if v_count>p_limit then raise exception 'Too many actions. Wait a moment and try again'; end if;
 delete from public.game_action_counters where window_started_at<now()-interval '1 day';
end $$;
revoke all on function public.consume_game_action(uuid,text,integer,integer) from public,anon,authenticated;

create or replace function public.create_game_room(p_nickname text,p_mode text)
returns jsonb language plpgsql security definer set search_path=public,auth,extensions as $$
declare v_id uuid; v_code text; v_limit integer; v_attempt integer:=0;
begin
 if auth.uid() is null then raise exception 'Join as a guest before creating a room'; end if;
 if char_length(trim(p_nickname)) not between 2 and 18 then raise exception 'Nickname must be 2-18 characters'; end if;
 if p_mode is null or p_mode not in ('classic','duel') then raise exception 'Unknown game mode'; end if;
 perform public.consume_game_action(null,'create_room',3,600);
 perform public.sweep_expired_game_rooms();
 v_limit:=case when p_mode='duel' then 2 else 8 end;
 loop
  v_attempt:=v_attempt+1;
  v_code:=(select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',(get_byte(gen_random_bytes(1),0)%32)+1,1),'') from generate_series(1,6));
  begin insert into public.game_rooms(code,mode,host_user_id) values(v_code,p_mode,auth.uid()) returning id into v_id; exit;
  exception when unique_violation then if v_attempt>=10 then raise exception 'Could not allocate a room code. Please try again'; end if;
  end;
 end loop;
 insert into public.game_players(room_id,user_id,nickname,last_seen_at) values(v_id,auth.uid(),trim(p_nickname),now());
 return public.get_game_room(v_id);
end $$;

create or replace function public.join_game_room(p_nickname text,p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_name text; v_suffix text; v_n integer:=2; v_room jsonb;
begin
 if auth.uid() is null then raise exception 'Join as a guest before joining a room'; end if;
 if char_length(trim(p_nickname)) not between 2 and 18 then raise exception 'Nickname must be 2-18 characters'; end if;
 perform public.consume_game_action(null,'join_room',8,60);
 perform public.sweep_expired_game_rooms();
 select * into r from public.game_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'Room not found. Check the code and try again'; end if;
 if r.expires_at<=clock_timestamp() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 if r.status<>'lobby' then raise exception 'This room has already started'; end if;
 if not exists(select 1 from public.game_players where room_id=r.id and user_id=auth.uid()) and (select count(*) from public.game_players where room_id=r.id)>=r.max_players then raise exception 'This room is full'; end if;
 v_name:=trim(p_nickname);
 while exists(select 1 from public.game_players where room_id=r.id and user_id<>auth.uid() and lower(nickname)=lower(v_name)) loop
  v_suffix:=' ('||v_n::text||')'; v_name:=left(trim(p_nickname),18-char_length(v_suffix))||v_suffix; v_n:=v_n+1;
  if v_n>100 then raise exception 'Could not assign a unique display name in this room'; end if;
 end loop;
 insert into public.game_players(room_id,user_id,nickname,last_seen_at) values(r.id,auth.uid(),v_name,now())
 on conflict(room_id,user_id) do update set nickname=excluded.nickname,last_seen_at=now();
 v_room:=public.get_game_room(r.id);
 return v_room||jsonb_build_object('nickname_adjusted',lower(v_name)<>lower(trim(p_nickname)),'joined_as',v_name);
end $$;

create or replace function public.touch_game_room(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_host_seen timestamptz; v_next_host uuid;
begin
 if auth.uid() is null then raise exception 'Sign in as a guest first'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 if r.expires_at<=clock_timestamp() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 perform public.consume_game_action(p_room_id,'heartbeat',10,60);
 select last_seen_at into v_host_seen from public.game_players where room_id=p_room_id and user_id=r.host_user_id;
 update public.game_players set last_seen_at=clock_timestamp() where room_id=p_room_id and user_id=auth.uid();
 if v_host_seen is null or v_host_seen<=clock_timestamp()-interval '45 seconds' then
  select user_id into v_next_host from public.game_players where room_id=p_room_id and last_seen_at>clock_timestamp()-interval '45 seconds' order by joined_at limit 1;
  if v_next_host is not null and v_next_host<>r.host_user_id then update public.game_rooms set host_user_id=v_next_host where id=p_room_id; end if;
 end if;
 return public.get_game_room(p_room_id);
end $$;

create or replace function public.resume_my_room()
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_room uuid;
begin
 if auth.uid() is null then return null; end if;
 perform public.consume_game_action(null,'resume_room',10,60);
 perform public.sweep_expired_game_rooms();
 select r.id into v_room from public.game_rooms r join public.game_players p on p.room_id=r.id
 where p.user_id=auth.uid() and r.expires_at>clock_timestamp() order by p.last_seen_at desc,p.joined_at desc limit 1;
 if v_room is null then return null; end if;
 perform public.touch_game_room(v_room);
 return jsonb_build_object('id',v_room);
end $$;

create or replace function public.begin_game_round(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_count integer; v_round smallint; v_spy uuid; v_last_spy uuid; v_category text; v_location text;
begin
 if auth.uid() is null then raise exception 'Sign in as a guest first'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 if r.expires_at<=clock_timestamp() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 if r.host_user_id<>auth.uid() then raise exception 'Only the host can start the next round'; end if;
 if r.phase not in ('lobby','round_results') then raise exception 'The current round is still in progress'; end if;
 if r.round_no=0 then
  select count(*) into v_count from public.game_players where room_id=p_room_id;
  if (r.mode='classic' and (v_count<3 or v_count>8)) or (r.mode='duel' and v_count<>2) then raise exception 'Player count does not match this game mode'; end if;
 elsif r.round_no>=3 then raise exception 'The three-round game is complete'; end if;
 perform public.consume_game_action(p_room_id,'begin_round',4,60);
 v_round:=r.round_no+1;
 if r.mode='duel' and v_round>1 then
  select spy_user_id into v_last_spy from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
  select user_id into v_spy from public.game_players where room_id=p_room_id and user_id<>v_last_spy;
 else select user_id into v_spy from public.game_players where room_id=p_room_id order by random() limit 1; end if;
 select category,location into v_category,v_location from public.game_locations order by random() limit 1;
 if v_spy is null or v_location is null then raise exception 'Could not assign this round'; end if;
 insert into public.game_rounds(room_id,round_no,category,location,spy_user_id) values(p_room_id,v_round,v_category,v_location,v_spy);
 if r.round_no=0 then update public.game_players set score=0 where room_id=p_room_id; end if;
 update public.game_rooms set status='playing',phase='investigation',round_no=v_round,phase_deadline=clock_timestamp()+interval '90 seconds' where id=p_room_id;
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.send_game_message(p_room_id uuid,p_body text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_name text; v_row public.game_messages%rowtype;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or r.expires_at<=clock_timestamp() then raise exception 'This room has expired or is unavailable'; end if;
 if r.phase<>'investigation' or r.phase_deadline<=clock_timestamp() then raise exception 'Investigation time is over'; end if;
 if p_body is null or char_length(trim(p_body)) not between 1 and 280 then raise exception 'Message must be 1-280 characters'; end if;
 perform public.consume_game_action(p_room_id,'chat',5,10);
 select nickname into v_name from public.game_players where room_id=p_room_id and user_id=auth.uid();
 insert into public.game_messages(room_id,round_no,user_id,nickname,body) values(p_room_id,r.round_no,auth.uid(),v_name,trim(p_body)) returning * into v_row;
 return jsonb_build_object('id',v_row.id,'nickname',v_row.nickname,'body',v_row.body,'created_at',v_row.created_at,'user_id',v_row.user_id);
end $$;

create or replace function public.cast_game_vote(p_room_id uuid,p_target uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_round public.game_rounds%rowtype; v_agent_count integer; v_voted integer;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or r.expires_at<=clock_timestamp() then raise exception 'This room has expired or is unavailable'; end if;
 select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
 if not found then raise exception 'No active round'; end if;
 if r.phase<>'voting' or r.phase_deadline<=clock_timestamp() then raise exception 'Voting is closed'; end if;
 if auth.uid()=v_round.spy_user_id then raise exception 'The Spy cannot cast an Agent vote'; end if;
 if p_target=auth.uid() or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=p_target) then raise exception 'Choose another player in this room'; end if;
 perform public.consume_game_action(p_room_id,'vote',5,20);
 insert into public.game_votes(room_id,round_no,voter_user_id,target_user_id) values(p_room_id,r.round_no,auth.uid(),p_target)
 on conflict(room_id,round_no,voter_user_id) do update set target_user_id=excluded.target_user_id,submitted_at=now();
 select count(*) into v_agent_count from public.game_players where room_id=p_room_id and user_id<>v_round.spy_user_id;
 select count(*) into v_voted from public.game_votes where room_id=p_room_id and round_no=r.round_no;
 if v_voted>=v_agent_count then perform public.resolve_game_vote(p_room_id); end if;
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.submit_spy_guess(p_room_id uuid,p_guess text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_round public.game_rounds%rowtype;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or r.expires_at<=clock_timestamp() then raise exception 'This room has expired or is unavailable'; end if;
 select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
 if not found then raise exception 'No active round'; end if;
 if r.phase<>'spy_guess' or r.phase_deadline<=clock_timestamp() then raise exception 'The guess window is closed'; end if;
 if auth.uid()<>v_round.spy_user_id then raise exception 'Only the Spy can guess'; end if;
 if p_guess is null or char_length(trim(p_guess)) not between 2 and 80 then raise exception 'Enter a location guess'; end if;
 perform public.consume_game_action(p_room_id,'spy_guess',2,20);
 perform public.finish_game_round(p_room_id,'spy_caught',trim(p_guess));
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.close_game_room(p_room_id uuid)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in as a guest first'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 if r.host_user_id<>auth.uid() then raise exception 'Only the host can close this room'; end if;
 if r.phase<>'lobby' then raise exception 'A game that has started cannot be closed from the lobby'; end if;
 perform public.consume_game_action(p_room_id,'close_room',3,60);
 delete from public.game_rooms where id=p_room_id;
 return true;
end $$;

create or replace function public.leave_game_room(p_room_id uuid)
returns boolean language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_next uuid;
begin
 if auth.uid() is null then raise exception 'Not signed in'; end if;
 perform public.sweep_expired_game_rooms();
 select * into r from public.game_rooms where id=p_room_id and phase in ('lobby','finished') for update;
 if not found or not public.is_game_room_member(p_room_id) then raise exception 'Room is expired or membership is no longer available'; end if;
 perform public.consume_game_action(p_room_id,'leave_room',4,60);
 delete from public.game_players where room_id=p_room_id and user_id=auth.uid();
 if not found then raise exception 'Room membership not found'; end if;
 if r.host_user_id=auth.uid() then
  select user_id into v_next from public.game_players where room_id=p_room_id order by joined_at limit 1;
  if v_next is null then delete from public.game_rooms where id=p_room_id;
  else update public.game_rooms set host_user_id=v_next where id=p_room_id; end if;
 end if;
 return true;
end $$;

revoke all on function public.create_game_room(text,text),public.join_game_room(text,text),public.get_game_room(uuid),public.resume_my_room(),public.touch_game_room(uuid),public.close_game_room(uuid),public.leave_game_room(uuid),public.begin_game_round(uuid),public.send_game_message(uuid,text),public.cast_game_vote(uuid,uuid),public.submit_spy_guess(uuid,text),public.advance_game_clock(uuid),public.get_game_state(uuid),public.sweep_expired_game_rooms() from public,anon,authenticated;
grant execute on function public.create_game_room(text,text),public.join_game_room(text,text),public.get_game_room(uuid),public.resume_my_room(),public.touch_game_room(uuid),public.close_game_room(uuid),public.leave_game_room(uuid),public.begin_game_round(uuid),public.send_game_message(uuid,text),public.cast_game_vote(uuid,uuid),public.submit_spy_guess(uuid,text),public.advance_game_clock(uuid),public.get_game_state(uuid) to authenticated;





create or replace function public.sweep_expired_game_rooms() returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_deleted integer;
begin
 delete from public.game_rooms where expires_at<=clock_timestamp();
 get diagnostics v_deleted=row_count;
 return v_deleted;
end $$;
revoke all on function public.sweep_expired_game_rooms() from public,anon,authenticated;

create or replace function public.reject_expired_room_update() returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
 if old.expires_at<=clock_timestamp() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 return new;
end $$;
revoke all on function public.reject_expired_room_update() from public,anon,authenticated;

create or replace function public.reject_expired_room_child_write() returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
 if not exists(select 1 from public.game_rooms where id=new.room_id and expires_at>clock_timestamp()) then raise exception 'This room has expired or is no longer available'; end if;
 return new;
end $$;
revoke all on function public.reject_expired_room_child_write() from public,anon,authenticated;

create or replace function public.advance_game_clock(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or r.expires_at<=clock_timestamp() then raise exception 'This room has expired or is unavailable'; end if;
 if r.phase_deadline is null or r.phase_deadline>clock_timestamp() then return public.get_game_state(p_room_id); end if;
 if r.phase='investigation' then update public.game_rooms set phase='voting',phase_deadline=clock_timestamp()+interval '20 seconds' where id=p_room_id;
 elsif r.phase='voting' then perform public.resolve_game_vote(p_room_id);
 elsif r.phase='spy_guess' then perform public.finish_game_round(p_room_id,'spy_caught',null);
 end if;
 return public.get_game_state(p_room_id);
end $$;




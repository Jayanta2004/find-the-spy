alter table public.game_rooms add column if not exists expires_at timestamptz not null default (now()+interval '24 hours');
alter table public.game_players add column if not exists last_seen_at timestamptz not null default now();
create index if not exists game_rooms_expiry_idx on public.game_rooms(expires_at);

create or replace function public.sweep_expired_game_rooms() returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_deleted integer;
begin
 delete from public.game_rooms where expires_at<=now();
 get diagnostics v_deleted=row_count;
 return v_deleted;
end $$;
revoke all on function public.sweep_expired_game_rooms() from public,anon;
grant execute on function public.sweep_expired_game_rooms() to authenticated;

create or replace function public.create_game_room(p_nickname text,p_mode text) returns jsonb language plpgsql security definer set search_path=public,auth,extensions as $$
declare v_id uuid; v_code text; v_limit int; v_attempt integer:=0;
begin
 if auth.uid() is null then raise exception 'Join as a guest before creating a room'; end if;
 if char_length(trim(p_nickname)) not between 2 and 18 then raise exception 'Nickname must be 2–18 characters'; end if;
 if p_mode not in ('classic','duel') then raise exception 'Unknown game mode'; end if;
 perform public.sweep_expired_game_rooms();
 v_limit:=case when p_mode='duel' then 2 else 8 end;
 loop
  v_attempt:=v_attempt+1;
  v_code:=(select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',(get_byte(gen_random_bytes(1),0)%32)+1,1),'') from generate_series(1,6));
  begin insert into public.game_rooms(code,mode,host_user_id) values(v_code,p_mode,auth.uid()) returning id into v_id; exit;
  exception when unique_violation then if v_attempt>=10 then raise exception 'Could not allocate a room code. Please try again'; end if;
  end;
 end loop;
 insert into public.game_players(room_id,user_id,nickname) values(v_id,auth.uid(),trim(p_nickname));
 return jsonb_build_object('id',v_id,'code',v_code,'mode',p_mode,'status','lobby','phase','lobby','round_no',0,'host_user_id',auth.uid(),'max_players',v_limit,'expires_at',now()+interval '24 hours','players',jsonb_build_array(jsonb_build_object('id',auth.uid(),'nickname',trim(p_nickname),'score',0,'is_me',true)));
end $$;

create or replace function public.join_game_room(p_nickname text,p_code text) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_limit integer; v_name text; v_suffix text; v_n integer:=2; v_room jsonb;
begin
 if auth.uid() is null then raise exception 'Join as a guest before joining a room'; end if;
 if char_length(trim(p_nickname)) not between 2 and 18 then raise exception 'Nickname must be 2–18 characters'; end if;
 select * into r from public.game_rooms where code=upper(trim(p_code)) for update;
 if not found then raise exception 'Room not found. Check the code and try again'; end if;
 if r.expires_at<=now() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 if r.status<>'lobby' then raise exception 'This room has already started'; end if;
 v_limit:=r.max_players;
 if not exists(select 1 from public.game_players where room_id=r.id and user_id=auth.uid()) and (select count(*) from public.game_players where room_id=r.id)>=v_limit then raise exception 'This room is full'; end if;
 v_name:=trim(p_nickname);
 while exists(select 1 from public.game_players where room_id=r.id and user_id<>auth.uid() and lower(nickname)=lower(v_name)) loop
  v_suffix:=' ('||v_n::text||')';
  v_name:=left(trim(p_nickname),18-char_length(v_suffix))||v_suffix;
  v_n:=v_n+1;
  if v_n>100 then raise exception 'Could not assign a unique display name in this room'; end if;
 end loop;
 insert into public.game_players(room_id,user_id,nickname,last_seen_at) values(r.id,auth.uid(),v_name,now()) on conflict(room_id,user_id) do update set nickname=excluded.nickname,last_seen_at=now();
 v_room:=public.get_game_room(r.id);
 return v_room||jsonb_build_object('nickname_adjusted',lower(v_name)<>lower(trim(p_nickname)),'joined_as',v_name);
end $$;

create or replace function public.get_game_room(p_room_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_players jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id;
 if not found then raise exception 'Room not found'; end if;
 if r.expires_at<=now() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'nickname',p.nickname,'score',p.score,'is_me',p.user_id=auth.uid()) order by p.joined_at),'[]'::jsonb) into v_players from public.game_players p where p.room_id=r.id;
 return jsonb_build_object('id',r.id,'code',r.code,'mode',r.mode,'status',r.status,'phase',r.phase,'round_no',r.round_no,'phase_deadline',r.phase_deadline,'host_user_id',r.host_user_id,'max_players',r.max_players,'expires_at',r.expires_at,'players',v_players);
end $$;

create or replace function public.resume_my_room() returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_room uuid;
begin
 if auth.uid() is null then return null; end if;
 select r.id into v_room from public.game_rooms r join public.game_players p on p.room_id=r.id where p.user_id=auth.uid() and r.expires_at>now() order by p.last_seen_at desc,p.joined_at desc limit 1;
 if v_room is null then return null; end if;
 return jsonb_build_object('id',v_room);
end $$;

create or replace function public.close_game_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype;
begin
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Room access denied'; end if;
 if r.host_user_id<>auth.uid() then raise exception 'Only the host can close this room'; end if;
 if r.phase<>'lobby' then raise exception 'A game that has started cannot be closed from the lobby'; end if;
 delete from public.game_rooms where id=p_room_id;
 return true;
end $$;

revoke all on function public.resume_my_room(),public.close_game_room(uuid) from public,anon;
grant execute on function public.resume_my_room(),public.close_game_room(uuid) to authenticated;
create or replace function public.reject_expired_room_update() returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
 if old.expires_at<=now() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 return new;
end $$;
drop trigger if exists game_rooms_reject_expired_update on public.game_rooms;
create trigger game_rooms_reject_expired_update before update on public.game_rooms for each row execute function public.reject_expired_room_update();
revoke all on function public.reject_expired_room_update() from public,anon,authenticated;

create or replace function public.reject_expired_room_child_write() returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
 if not exists(select 1 from public.game_rooms where id=new.room_id and expires_at>now()) then raise exception 'This room has expired or is no longer available'; end if;
 return new;
end $$;
drop trigger if exists game_messages_reject_expired_write on public.game_messages;
create trigger game_messages_reject_expired_write before insert on public.game_messages for each row execute function public.reject_expired_room_child_write();
drop trigger if exists game_votes_reject_expired_write on public.game_votes;
create trigger game_votes_reject_expired_write before insert or update on public.game_votes for each row execute function public.reject_expired_room_child_write();
revoke all on function public.reject_expired_room_child_write() from public,anon,authenticated;

create or replace function public.get_game_state(p_room_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_players jsonb; v_messages jsonb; v_round public.game_rounds%rowtype; v_is_spy boolean; v_reveal boolean; v_role jsonb; v_my_vote uuid;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id;
 if not found then raise exception 'Room not found'; end if;
 if r.expires_at<=now() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'nickname',p.nickname,'score',p.score,'is_me',p.user_id=auth.uid()) order by p.joined_at),'[]'::jsonb) into v_players from public.game_players p where p.room_id=p_room_id;
 if r.round_no>0 then
  select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
  v_is_spy:=v_round.spy_user_id=auth.uid();
  v_reveal:=r.phase in ('round_results','finished');
  select target_user_id into v_my_vote from public.game_votes where room_id=p_room_id and round_no=r.round_no and voter_user_id=auth.uid();
  v_role:=jsonb_build_object('number',v_round.round_no,'category',v_round.category,'role',case when v_is_spy then 'spy' else 'agent' end,'location',case when not v_is_spy or v_reveal then v_round.location else null end,'caught',v_round.caught_user_id is not null,'spy_guess',case when v_reveal then v_round.spy_guess else null end,'spy_guess_correct',case when v_reveal then v_round.spy_guess_correct else null end,'outcome',case when v_reveal then v_round.outcome else null end,'spy_nickname',case when v_reveal then (select nickname from public.game_players where room_id=p_room_id and user_id=v_round.spy_user_id) else null end,'my_vote',v_my_vote);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'user_id',m.user_id,'nickname',m.nickname,'body',m.body,'created_at',m.created_at) order by m.created_at),'[]'::jsonb) into v_messages from public.game_messages m where m.room_id=p_room_id and m.round_no=r.round_no;
 return jsonb_build_object('id',r.id,'code',r.code,'mode',r.mode,'status',r.status,'phase',r.phase,'round_no',r.round_no,'phase_deadline',r.phase_deadline,'host_user_id',r.host_user_id,'max_players',r.max_players,'expires_at',r.expires_at,'players',v_players,'messages',v_messages,'round',v_role);
end $$;

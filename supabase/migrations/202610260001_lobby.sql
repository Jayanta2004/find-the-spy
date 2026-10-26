create extension if not exists pgcrypto;
create table if not exists public.game_rooms (
 id uuid primary key default gen_random_uuid(), code text not null unique check(code ~ '^[A-Z0-9]{6}$'), mode text not null check(mode in ('classic','duel')), status text not null default 'lobby' check(status in ('lobby','playing','finished')), host_user_id uuid not null references auth.users(id) on delete cascade, created_at timestamptz not null default now(), max_players smallint generated always as (case when mode='duel' then 2 else 8 end) stored
);
create table if not exists public.game_players (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.game_rooms(id) on delete cascade, user_id uuid not null references auth.users(id) on delete cascade, nickname text not null check(char_length(nickname) between 2 and 18), joined_at timestamptz not null default now(), unique(room_id,user_id)
);
create index if not exists game_players_room_idx on public.game_players(room_id,joined_at);
alter table public.game_rooms enable row level security;
alter table public.game_players enable row level security;
create or replace function public.is_game_room_member(p_room_id uuid) returns boolean language sql stable security definer set search_path=public,auth as $$ select exists(select 1 from public.game_players where room_id=p_room_id and user_id=auth.uid()) $$;
revoke all on function public.is_game_room_member(uuid) from public,anon;
grant execute on function public.is_game_room_member(uuid) to authenticated;
drop policy if exists "Room members can read room" on public.game_rooms;
create policy "Room members can read room" on public.game_rooms for select to authenticated using (public.is_game_room_member(id));
drop policy if exists "Room members can read roster" on public.game_players;
create policy "Room members can read roster" on public.game_players for select to authenticated using (public.is_game_room_member(room_id));
revoke all on public.game_rooms,public.game_players from anon,authenticated;
grant select on public.game_rooms,public.game_players to authenticated;
create or replace function public.create_game_room(p_nickname text,p_mode text) returns jsonb language plpgsql security definer set search_path=public,auth,extensions as $$
declare v_id uuid; v_code text; v_limit int;
begin
 if auth.uid() is null then raise exception 'Join as a guest before creating a room'; end if;
 if char_length(trim(p_nickname)) not between 2 and 18 then raise exception 'Nickname must be 2–18 characters'; end if;
 if p_mode not in ('classic','duel') then raise exception 'Unknown game mode'; end if;
 v_limit:=case when p_mode='duel' then 2 else 8 end;
 loop
  v_code:=(select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',(get_byte(gen_random_bytes(1),0)%32)+1,1),'') from generate_series(1,6));
  begin insert into public.game_rooms(code,mode,host_user_id) values(v_code,p_mode,auth.uid()) returning id into v_id; exit;
  exception when unique_violation then null; end;
 end loop;
 insert into public.game_players(room_id,user_id,nickname) values(v_id,auth.uid(),trim(p_nickname));
 return jsonb_build_object('id',v_id,'code',v_code,'mode',p_mode,'status','lobby','max_players',v_limit,'players',jsonb_build_array(jsonb_build_object('id',auth.uid(),'nickname',trim(p_nickname))));
end $$;
create or replace function public.join_game_room(p_nickname text,p_code text) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_limit int;
begin
 if auth.uid() is null then raise exception 'Join as a guest before joining a room'; end if;
 if char_length(trim(p_nickname)) not between 2 and 18 then raise exception 'Nickname must be 2–18 characters'; end if;
 select * into r from public.game_rooms where code=upper(trim(p_code)) and status='lobby' for update;
 if not found then raise exception 'Room not found or no longer accepting players'; end if;
 v_limit:=r.max_players;
 if not exists(select 1 from public.game_players where room_id=r.id and user_id=auth.uid()) and (select count(*) from public.game_players where room_id=r.id)>=v_limit then raise exception 'This room is full'; end if;
 insert into public.game_players(room_id,user_id,nickname) values(r.id,auth.uid(),trim(p_nickname)) on conflict(room_id,user_id) do update set nickname=excluded.nickname;
 return public.get_game_room(r.id);
end $$;
create or replace function public.get_game_room(p_room_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_players jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id;
 if not found then raise exception 'Room not found'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'nickname',p.nickname) order by p.joined_at),'[]'::jsonb) into v_players from public.game_players p where p.room_id=r.id;
 return jsonb_build_object('id',r.id,'code',r.code,'mode',r.mode,'status',r.status,'max_players',r.max_players,'players',v_players);
end $$;
create or replace function public.leave_game_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_next uuid;
begin
 if auth.uid() is null then raise exception 'Not signed in'; end if;
 select * into r from public.game_rooms where id=p_room_id and status='lobby' for update;
 if not found then raise exception 'Room is no longer in the lobby'; end if;
 delete from public.game_players where room_id=p_room_id and user_id=auth.uid();
 if not found then raise exception 'Room membership not found'; end if;
 if r.host_user_id=auth.uid() then
  select user_id into v_next from public.game_players where room_id=p_room_id order by joined_at limit 1;
  if v_next is null then delete from public.game_rooms where id=p_room_id;
  else update public.game_rooms set host_user_id=v_next where id=p_room_id; end if;
 end if;
 return true;
end $$;
revoke all on function public.create_game_room(text,text),public.join_game_room(text,text),public.get_game_room(uuid),public.leave_game_room(uuid) from public,anon;
grant execute on function public.create_game_room(text,text),public.join_game_room(text,text),public.get_game_room(uuid),public.leave_game_room(uuid) to authenticated;
do $$ begin alter publication supabase_realtime add table public.game_players; exception when duplicate_object then null; when undefined_object then null; end $$;





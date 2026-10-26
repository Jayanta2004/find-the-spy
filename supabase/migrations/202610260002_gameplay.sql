alter table public.game_rooms add column if not exists phase text not null default 'lobby' check (phase in ('lobby','investigation','voting','spy_guess','round_results','finished'));
alter table public.game_rooms add column if not exists round_no smallint not null default 0;
alter table public.game_rooms add column if not exists phase_deadline timestamptz;
alter table public.game_players add column if not exists score integer not null default 0;

create table if not exists public.game_locations (
 id bigint generated always as identity primary key,
 category text not null,
 location text not null,
 unique(category,location)
);
insert into public.game_locations(category,location) values
 ('Food & drink','Coffee shop'),('Food & drink','Sushi restaurant'),('Food & drink','Bakery'),('Food & drink','Food truck'),('Food & drink','Hotel bar'),
 ('Travel','Airport security'),('Travel','Train station'),('Travel','Cruise ship'),('Travel','Mountain lodge'),('Travel','Roadside motel'),
 ('Work','Newsroom'),('Work','Fire station'),('Work','Recording studio'),('Work','Research lab'),('Work','Construction site'),
 ('Culture','Art museum'),('Culture','Movie theater'),('Culture','Jazz club'),('Culture','Aquarium'),('Culture','Amusement park'),
 ('Everyday life','Dentist waiting room'),('Everyday life','Grocery store'),('Everyday life','Wedding reception'),('Everyday life','Summer camp'),('Everyday life','Public library')
on conflict(category,location) do nothing;

create table if not exists public.game_rounds (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.game_rooms(id) on delete cascade,
 round_no smallint not null, category text not null, location text not null, spy_user_id uuid not null references auth.users(id),
 caught_user_id uuid references auth.users(id), spy_guess text, spy_guess_correct boolean, outcome text,
 created_at timestamptz not null default now(), ended_at timestamptz, unique(room_id,round_no)
);
create table if not exists public.game_messages (
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.game_rooms(id) on delete cascade,
 round_no smallint not null, user_id uuid not null references auth.users(id), nickname text not null,
 body text not null check(char_length(body) between 1 and 280), created_at timestamptz not null default now()
);
create index if not exists game_messages_room_round_idx on public.game_messages(room_id,round_no,created_at);
create table if not exists public.game_votes (
 room_id uuid not null references public.game_rooms(id) on delete cascade, round_no smallint not null,
 voter_user_id uuid not null references auth.users(id), target_user_id uuid not null references auth.users(id),
 submitted_at timestamptz not null default now(), primary key(room_id,round_no,voter_user_id), check(voter_user_id<>target_user_id)
);

alter table public.game_locations enable row level security;
alter table public.game_rounds enable row level security;
alter table public.game_messages enable row level security;
alter table public.game_votes enable row level security;
revoke all on public.game_locations,public.game_rounds,public.game_messages,public.game_votes from anon,authenticated;
grant select on public.game_messages to authenticated;
drop policy if exists "Room members can read round chat" on public.game_messages;
create policy "Room members can read round chat" on public.game_messages for select to authenticated using (public.is_game_room_member(room_id));

grant select on public.game_rooms,public.game_players to authenticated;

create or replace function public.finish_game_round(p_room_id uuid,p_outcome text,p_guess text default null) returns void language plpgsql security definer set search_path=public,auth as $$
declare v_round public.game_rounds%rowtype; v_player record; v_correct boolean:=false;
begin
 select gr.* into v_round from public.game_rounds gr join public.game_rooms r on r.id=gr.room_id and r.round_no=gr.round_no where gr.room_id=p_room_id for update;
 if not found then return; end if;
 if p_outcome='spy_caught' then v_correct:=lower(trim(coalesce(p_guess,'')))=lower(v_round.location); end if;
 update public.game_rounds set spy_guess=p_guess,spy_guess_correct=v_correct,outcome=p_outcome,ended_at=now(),caught_user_id=case when p_outcome='spy_escaped' then null else spy_user_id end where id=v_round.id;
 if p_outcome='spy_escaped' then update public.game_players set score=score+2 where room_id=p_room_id and user_id=v_round.spy_user_id;
 elsif v_correct then update public.game_players set score=score+5 where room_id=p_room_id and user_id=v_round.spy_user_id;
 else
  update public.game_players set score=score+2+case when p_outcome='spy_caught' then 3 else 0 end where room_id=p_room_id and user_id<>v_round.spy_user_id;
 end if;
 update public.game_rooms set phase=case when round_no=3 then 'finished' else 'round_results' end,status=case when round_no=3 then 'finished' else 'playing' end,phase_deadline=null where id=p_room_id;
end $$;

create or replace function public.resolve_game_vote(p_room_id uuid) returns void language plpgsql security definer set search_path=public,auth as $$
declare v_round public.game_rounds%rowtype; v_agent_count integer; v_spy_votes integer;
begin
 select gr.* into v_round from public.game_rounds gr join public.game_rooms r on r.id=gr.room_id and r.round_no=gr.round_no where gr.room_id=p_room_id for update;
 if not found then return; end if;
 select count(*) into v_agent_count from public.game_players where room_id=p_room_id and user_id<>v_round.spy_user_id;
 select count(*) into v_spy_votes from public.game_votes where room_id=p_room_id and round_no=v_round.round_no and target_user_id=v_round.spy_user_id;
 if v_spy_votes > v_agent_count/2 then
  update public.game_rounds set caught_user_id=v_round.spy_user_id where id=v_round.id;
  update public.game_rooms set phase='spy_guess',phase_deadline=now()+interval '20 seconds' where id=p_room_id;
 else perform public.finish_game_round(p_room_id,'spy_escaped',null);
 end if;
end $$;

create or replace function public.begin_game_round(p_room_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_count integer; v_round smallint; v_spy uuid; v_last_spy uuid; v_category text; v_location text;
begin
 if auth.uid() is null then raise exception 'Sign in as a guest first'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Room access denied'; end if;
 if r.host_user_id<>auth.uid() then raise exception 'Only the host can start the next round'; end if;
 if r.phase not in ('lobby','round_results') then raise exception 'The current round is still in progress'; end if;
 if r.round_no=0 then
  select count(*) into v_count from public.game_players where room_id=p_room_id;
  if (r.mode='classic' and (v_count<3 or v_count>8)) or (r.mode='duel' and v_count<>2) then raise exception 'Classic needs 3â€“8 players; Spy Duel needs exactly 2'; end if;
 elsif r.round_no>=3 then raise exception 'The three-round game is complete';
 end if;
 v_round:=r.round_no+1;
 if r.mode='duel' and v_round=2 then
  select spy_user_id into v_last_spy from public.game_rounds where room_id=p_room_id and round_no=1;
  select user_id into v_spy from public.game_players where room_id=p_room_id and user_id<>v_last_spy limit 1;
 else select user_id into v_spy from public.game_players where room_id=p_room_id order by random() limit 1;
 end if;
 select category,location into v_category,v_location from public.game_locations order by random() limit 1;
 insert into public.game_rounds(room_id,round_no,category,location,spy_user_id) values(p_room_id,v_round,v_category,v_location,v_spy);
 if r.round_no=0 then update public.game_players set score=0 where room_id=p_room_id; end if;
 update public.game_rooms set status='playing',phase='investigation',round_no=v_round,phase_deadline=now()+interval '90 seconds' where id=p_room_id;
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.send_game_message(p_room_id uuid,p_body text) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_name text; v_row public.game_messages%rowtype;
begin
 select * into r from public.game_rooms where id=p_room_id;
 if not found or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 if r.phase<>'investigation' or r.phase_deadline<=now() then raise exception 'Investigation time is over'; end if;
 if char_length(trim(p_body)) not between 1 and 280 then raise exception 'Message must be 1â€“280 characters'; end if;
 select nickname into v_name from public.game_players where room_id=p_room_id and user_id=auth.uid();
 insert into public.game_messages(room_id,round_no,user_id,nickname,body) values(p_room_id,r.round_no,auth.uid(),v_name,trim(p_body)) returning * into v_row;
 return jsonb_build_object('id',v_row.id,'nickname',v_row.nickname,'body',v_row.body,'created_at',v_row.created_at,'user_id',v_row.user_id);
end $$;

create or replace function public.cast_game_vote(p_room_id uuid,p_target uuid) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_round public.game_rounds%rowtype; v_agent_count integer; v_voted integer;
begin
 select * into r from public.game_rooms where id=p_room_id for update;
 select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 if r.phase<>'voting' or r.phase_deadline<=now() then raise exception 'Voting is closed'; end if;
 if auth.uid()=v_round.spy_user_id then raise exception 'The Spy cannot cast an Agent vote'; end if;
 if p_target=auth.uid() or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=p_target) then raise exception 'Choose another player in this room'; end if;
 insert into public.game_votes(room_id,round_no,voter_user_id,target_user_id) values(p_room_id,r.round_no,auth.uid(),p_target) on conflict(room_id,round_no,voter_user_id) do update set target_user_id=excluded.target_user_id,submitted_at=now();
 select count(*) into v_agent_count from public.game_players where room_id=p_room_id and user_id<>v_round.spy_user_id;
 select count(*) into v_voted from public.game_votes where room_id=p_room_id and round_no=r.round_no;
 if v_voted>=v_agent_count then perform public.resolve_game_vote(p_room_id); end if;
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.submit_spy_guess(p_room_id uuid,p_guess text) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_round public.game_rounds%rowtype;
begin
 select * into r from public.game_rooms where id=p_room_id for update;
 select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 if r.phase<>'spy_guess' or r.phase_deadline<=now() then raise exception 'The guess window is closed'; end if;
 if auth.uid()<>v_round.spy_user_id then raise exception 'Only the Spy can guess'; end if;
 if char_length(trim(p_guess)) not between 2 and 80 then raise exception 'Enter a location guess'; end if;
 perform public.finish_game_round(p_room_id,'spy_caught',trim(p_guess));
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.advance_game_clock(p_room_id uuid) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if r.phase_deadline is null or r.phase_deadline>now() then return public.get_game_state(p_room_id); end if;
 if r.phase='investigation' then update public.game_rooms set phase='voting',phase_deadline=now()+interval '20 seconds' where id=p_room_id;
 elsif r.phase='voting' then perform public.resolve_game_vote(p_room_id);
 elsif r.phase='spy_guess' then perform public.finish_game_round(p_room_id,'spy_caught',null);
 end if;
 return public.get_game_state(p_room_id);
end $$;

create or replace function public.get_game_state(p_room_id uuid) returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_players jsonb; v_messages jsonb; v_round public.game_rounds%rowtype; v_me text; v_is_spy boolean; v_reveal boolean; v_role jsonb; v_my_vote uuid;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'nickname',p.nickname,'score',p.score,'is_me',p.user_id=auth.uid()) order by p.joined_at),'[]'::jsonb) into v_players from public.game_players p where p.room_id=p_room_id;
 if r.round_no>0 then
  select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
  v_is_spy:=v_round.spy_user_id=auth.uid();
  v_reveal:=r.phase in ('round_results','finished');
  select target_user_id into v_my_vote from public.game_votes where room_id=p_room_id and round_no=r.round_no and voter_user_id=auth.uid();
  v_role:=jsonb_build_object('number',v_round.round_no,'category',v_round.category,'role',case when v_is_spy then 'spy' else 'agent' end,'location',case when not v_is_spy or v_reveal then v_round.location else null end,'caught',v_round.caught_user_id is not null,'spy_guess',case when v_reveal then v_round.spy_guess else null end,'spy_guess_correct',case when v_reveal then v_round.spy_guess_correct else null end,'outcome',case when v_reveal then v_round.outcome else null end,'spy_nickname',case when v_reveal then (select nickname from public.game_players where room_id=p_room_id and user_id=v_round.spy_user_id) else null end,'my_vote',v_my_vote);
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'user_id',m.user_id,'nickname',m.nickname,'body',m.body,'created_at',m.created_at) order by m.created_at),'[]'::jsonb) into v_messages from public.game_messages m where m.room_id=p_room_id and m.round_no=r.round_no;
 return jsonb_build_object('id',r.id,'code',r.code,'mode',r.mode,'status',r.status,'phase',r.phase,'round_no',r.round_no,'phase_deadline',r.phase_deadline,'host_user_id',r.host_user_id,'max_players',(select max_players from public.game_rooms where id=p_room_id),'players',v_players,'messages',v_messages,'round',v_role);
end $$;

revoke all on function public.finish_game_round(uuid,text,text),public.resolve_game_vote(uuid) from public,anon,authenticated;
revoke all on function public.begin_game_round(uuid),public.send_game_message(uuid,text),public.cast_game_vote(uuid,uuid),public.submit_spy_guess(uuid,text),public.advance_game_clock(uuid),public.get_game_state(uuid) from public,anon;
grant execute on function public.begin_game_round(uuid),public.send_game_message(uuid,text),public.cast_game_vote(uuid,uuid),public.submit_spy_guess(uuid,text),public.advance_game_clock(uuid),public.get_game_state(uuid) to authenticated;

create or replace function public.leave_game_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path=public,auth as $$
declare r public.game_rooms%rowtype; v_next uuid;
begin
 if auth.uid() is null then raise exception 'Not signed in'; end if;
 select * into r from public.game_rooms where id=p_room_id and phase in ('lobby','finished') for update;
 if not found then raise exception 'You can leave after the current game is finished'; end if;
 delete from public.game_players where room_id=p_room_id and user_id=auth.uid();
 if not found then raise exception 'Room membership not found'; end if;
 if r.host_user_id=auth.uid() then
  select user_id into v_next from public.game_players where room_id=p_room_id order by joined_at limit 1;
  if v_next is null then delete from public.game_rooms where id=p_room_id;
  else update public.game_rooms set host_user_id=v_next where id=p_room_id; end if;
 end if;
 return true;
end $$;
grant execute on function public.leave_game_room(uuid) to authenticated;

do $$ begin alter publication supabase_realtime add table public.game_rooms; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.game_messages; exception when duplicate_object then null; when undefined_object then null; end $$;


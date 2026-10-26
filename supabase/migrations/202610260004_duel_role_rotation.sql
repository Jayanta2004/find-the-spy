-- Spy Duel has three rounds, so alternate the Spy on every round.
-- This function preserves server-side role/location assignment and private delivery.
create or replace function public.begin_game_round(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
 r public.game_rooms%rowtype;
 v_count integer;
 v_round smallint;
 v_spy uuid;
 v_last_spy uuid;
 v_category text;
 v_location text;
begin
 if auth.uid() is null then raise exception 'Sign in as a guest first'; end if;
 select * into r from public.game_rooms where id=p_room_id for update;
 if not found or not exists(select 1 from public.game_players where room_id=p_room_id and user_id=auth.uid()) then raise exception 'Room access denied'; end if;
 if r.host_user_id<>auth.uid() then raise exception 'Only the host can start the next round'; end if;
 if r.phase not in ('lobby','round_results') then raise exception 'The current round is still in progress'; end if;
 if r.round_no=0 then
  select count(*) into v_count from public.game_players where room_id=p_room_id;
  if (r.mode='classic' and (v_count<3 or v_count>8)) or (r.mode='duel' and v_count<>2) then
   raise exception 'Classic needs 3-8 players; Spy Duel needs exactly 2';
  end if;
 elsif r.round_no>=3 then
  raise exception 'The three-round game is complete';
 end if;

 v_round:=r.round_no+1;
 if r.mode='duel' and v_round>1 then
  select spy_user_id into v_last_spy from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
  select user_id into v_spy from public.game_players where room_id=p_room_id and user_id<>v_last_spy;
 else
  select user_id into v_spy from public.game_players where room_id=p_room_id order by random() limit 1;
 end if;
 select category,location into v_category,v_location from public.game_locations order by random() limit 1;
 if v_spy is null or v_location is null then raise exception 'Could not assign this round'; end if;

 insert into public.game_rounds(room_id,round_no,category,location,spy_user_id)
 values(p_room_id,v_round,v_category,v_location,v_spy);
 if r.round_no=0 then update public.game_players set score=0 where room_id=p_room_id; end if;
 update public.game_rooms set status='playing',phase='investigation',round_no=v_round,phase_deadline=now()+interval '90 seconds' where id=p_room_id;
 return public.get_game_state(p_room_id);
end
$$;

revoke all on function public.begin_game_round(uuid) from public,anon;
grant execute on function public.begin_game_round(uuid) to authenticated;

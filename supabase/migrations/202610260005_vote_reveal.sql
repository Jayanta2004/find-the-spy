-- Reveal anonymous vote totals only after the vote has resolved. The voter-to-target
-- rows remain inaccessible to clients through REST and are never returned by this RPC.
create or replace function public.get_game_state(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth
as $$
declare
 r public.game_rooms%rowtype;
 v_players jsonb;
 v_messages jsonb;
 v_round public.game_rounds%rowtype;
 v_is_spy boolean;
 v_reveal boolean;
 v_reveal_votes boolean;
 v_role jsonb;
 v_my_vote uuid;
 v_vote_tally jsonb;
 v_votes_cast integer;
begin
 if auth.uid() is null or not public.is_game_room_member(p_room_id) then raise exception 'Room access denied'; end if;
 select * into r from public.game_rooms where id=p_room_id;
 if not found then raise exception 'Room not found'; end if;
 if r.expires_at<=now() then raise exception 'This room has expired. Ask the host to create a new one'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'nickname',p.nickname,'score',p.score,'is_me',p.user_id=auth.uid()) order by p.joined_at),'[]'::jsonb)
 into v_players from public.game_players p where p.room_id=p_room_id;
 if r.round_no>0 then
  select * into v_round from public.game_rounds where room_id=p_room_id and round_no=r.round_no;
  v_is_spy:=v_round.spy_user_id=auth.uid();
  v_reveal:=r.phase in ('round_results','finished');
  v_reveal_votes:=r.phase in ('spy_guess','round_results','finished');
  select target_user_id into v_my_vote from public.game_votes where room_id=p_room_id and round_no=r.round_no and voter_user_id=auth.uid();
  if v_reveal_votes then
   select coalesce(jsonb_agg(jsonb_build_object('player_id',q.player_id,'nickname',q.nickname,'votes',q.votes) order by q.joined_at),'[]'::jsonb)
   into v_vote_tally
   from (
    select p.user_id as player_id,p.nickname,p.joined_at,count(v.voter_user_id)::integer as votes
    from public.game_players p
    left join public.game_votes v on v.room_id=p.room_id and v.round_no=r.round_no and v.target_user_id=p.user_id
    where p.room_id=p_room_id
    group by p.user_id,p.nickname,p.joined_at
   ) q;
   select count(*)::integer into v_votes_cast from public.game_votes where room_id=p_room_id and round_no=r.round_no;
  end if;
  v_role:=jsonb_build_object(
   'number',v_round.round_no,
   'category',v_round.category,
   'role',case when v_is_spy then 'spy' else 'agent' end,
   'location',case when not v_is_spy or v_reveal then v_round.location else null end,
   'caught',v_round.caught_user_id is not null,
   'spy_guess',case when v_reveal then v_round.spy_guess else null end,
   'spy_guess_correct',case when v_reveal then v_round.spy_guess_correct else null end,
   'outcome',case when v_reveal then v_round.outcome else null end,
   'spy_nickname',case when v_reveal then (select nickname from public.game_players where room_id=p_room_id and user_id=v_round.spy_user_id) else null end,
   'my_vote',v_my_vote,
   'vote_tally',case when v_reveal_votes then v_vote_tally else null end,
   'votes_cast',case when v_reveal_votes then v_votes_cast else null end
  );
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'user_id',m.user_id,'nickname',m.nickname,'body',m.body,'created_at',m.created_at) order by m.created_at),'[]'::jsonb)
 into v_messages from public.game_messages m where m.room_id=p_room_id and m.round_no=r.round_no;
 return jsonb_build_object('id',r.id,'code',r.code,'mode',r.mode,'status',r.status,'phase',r.phase,'round_no',r.round_no,'phase_deadline',r.phase_deadline,'host_user_id',r.host_user_id,'max_players',r.max_players,'expires_at',r.expires_at,'players',v_players,'messages',v_messages,'round',v_role);
end
$$;

revoke all on function public.get_game_state(uuid) from public,anon;
grant execute on function public.get_game_state(uuid) to authenticated;

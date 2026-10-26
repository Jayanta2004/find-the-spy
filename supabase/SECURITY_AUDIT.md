# Find the Spy: client payload and permission audit

This audit covers migrations 001–006. It describes the intended grants after applying them in order.

| Data/API | Authenticated client access | Secret exposure |
|---|---|---|
| `game_rooms` | SELECT under membership and unexpired-room RLS; writes only through validated RPCs | Room metadata, host id, mode, phase, deadline, expiry only |
| `game_players` | SELECT under membership and unexpired-room RLS; no client writes | Names, user ids, scores, presence timestamp; no role or location columns |
| `game_messages` | SELECT under membership and unexpired-room RLS; inserts only through `send_game_message` | User-authored chat only |
| `game_rounds` | No `anon` or `authenticated` table grants | Secret location and Spy assignment stay private |
| `game_locations` | No `anon` or `authenticated` table grants | Location bank stays private |
| `game_votes` | No `anon` or `authenticated` table grants | Individual voter-to-target mapping stays private |
| `game_action_counters` | RLS enabled; no client grants or policies | Rate-limit counters stay private |

## RPC payloads

- `create_game_room` and `join_game_room` return the room metadata and public roster, not round data.
- `get_game_room` and `touch_game_room` return room metadata and roster fields only.
- `resume_my_room` returns only the room id.
- `send_game_message` returns only the just-submitted message.
- `get_game_state`, `begin_game_round`, `cast_game_vote`, `submit_spy_guess`, and `advance_game_clock` use `auth.uid()` and membership checks. The `round` object contains only the caller's role; an active Spy receives a null location. Aggregate vote totals are returned only after voting resolves and never include voter ids. Location and Spy identity are revealed to everyone only in round results.
- Score updates happen in internal security-definer functions. Clients cannot update scores or call those internal functions.

## Mutation controls

RLS and grants block direct client writes to game tables. RPCs validate room membership, host status, mode player counts, current phase, deadlines, role, target membership, nickname/message/guess lengths, and room expiry. Message, vote-change, guess, room creation/join, start, heartbeat, resume, and room leave/close calls have per-anonymous-session limits. Advisory transaction locks and an atomic counter upsert prevent concurrent requests from bypassing each action window.

Presence is last-seen state, not a device identity proof. Host handover occurs after 45 seconds without a heartbeat and runs on the next active member heartbeat. Expired-room deletion is lazy (on create, join, or resume), while expiration is enforced immediately for reads and writes.

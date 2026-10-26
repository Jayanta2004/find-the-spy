import { createClient } from '@supabase/supabase-js'

const url = process.env.NEXT_PUBLIC_SUPABASE_URL
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
export const backendReady = Boolean(url && key && !url.includes('YOUR_PROJECT_ID') && !key.includes('YOUR_SUPABASE'))
export const supabase = backendReady ? createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } }) : null

export async function ensureGuestSession() {
  if (!supabase) throw new Error('Connect Supabase to enable shared rooms. See the setup steps in README.md.')
  const { data: { session }, error } = await supabase.auth.getSession()
  if (error) throw error
  if (session) return session
  const result = await supabase.auth.signInAnonymously()
  if (result.error) throw result.error
  return result.data.session
}

async function gameAction(action, args = {}, createSession = false) {
  if (!supabase) throw new Error('Shared rooms are not connected yet. Complete the Supabase setup first.')
  if (createSession) await ensureGuestSession()
  const { data: { session }, error: sessionError } = await supabase.auth.getSession()
  if (sessionError) throw sessionError
  if (!session?.access_token) throw new Error('Your guest session expired. Refresh the page and try again.')
  const response = await fetch('/api/game-action', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${session.access_token}` },
    body: JSON.stringify({ action, args }),
    cache: 'no-store'
  })
  let payload
  try { payload = await response.json() } catch { throw new Error('The game server returned an unexpected response.') }
  if (!response.ok) throw new Error(payload.error || 'That game action could not be completed.')
  return payload.data
}

async function directRead(action, args = {}) {
  if (!supabase) throw new Error('Shared rooms are not connected yet. Complete the Supabase setup first.')
  const { data, error } = await supabase.rpc(action, args)
  if (error) throw error
  return data
}

export const createRoom = (nickname, mode) => gameAction('create_game_room', { p_nickname: nickname, p_mode: mode }, true)
export const joinRoom = (nickname, code) => gameAction('join_game_room', { p_nickname: nickname, p_code: code }, true)
export async function resumeRoom() {
  if (!supabase) return null
  const { data: { session }, error } = await supabase.auth.getSession()
  if (error) throw error
  return session ? directRead('resume_my_room') : null
}
export const touchGameRoom = id => gameAction('touch_game_room', { p_room_id: id })
export const closeRoom = id => gameAction('close_game_room', { p_room_id: id })
export const getRoom = id => directRead('get_game_room', { p_room_id: id })
export const getGameState = id => directRead('get_game_state', { p_room_id: id })
export const beginGameRound = id => gameAction('begin_game_round', { p_room_id: id })
export async function sendGameMessage(id, body) {
  await gameAction('send_game_message', { p_room_id: id, p_body: body })
  return getGameState(id)
}
export const castGameVote = (id, target) => gameAction('cast_game_vote', { p_room_id: id, p_target: target })
export const submitSpyGuess = (id, guess) => gameAction('submit_spy_guess', { p_room_id: id, p_guess: guess })
export const advanceGameClock = id => gameAction('advance_game_clock', { p_room_id: id })
export const leaveRoom = id => gameAction('leave_game_room', { p_room_id: id })

export function subscribeRoom(id, callback) {
  if (!supabase) return () => {}
  let stopped = false
  let fallback = null
  const startFallback = () => { if (!fallback && !stopped) fallback = setInterval(callback, 5000) }
  const channel = supabase.channel('room:' + id)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'game_players', filter: 'room_id=eq.' + id }, callback)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'game_rooms', filter: 'id=eq.' + id }, callback)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'game_messages', filter: 'room_id=eq.' + id }, callback)
    .subscribe(status => {
      if (stopped) return
      if (status === 'SUBSCRIBED') { if (fallback) clearInterval(fallback); fallback = null; callback() }
      else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') startFallback()
    })
  return () => { stopped = true; if (fallback) clearInterval(fallback); supabase.removeChannel(channel) }
}

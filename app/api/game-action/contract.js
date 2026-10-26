const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const definitions = {
  create_game_room: ['p_nickname', 'p_mode'],
  join_game_room: ['p_nickname', 'p_code'],
  resume_my_room: [],
  touch_game_room: ['p_room_id'],
  close_game_room: ['p_room_id'],
  get_game_room: ['p_room_id'],
  get_game_state: ['p_room_id'],
  begin_game_round: ['p_room_id'],
  send_game_message: ['p_room_id', 'p_body'],
  cast_game_vote: ['p_room_id', 'p_target'],
  submit_spy_guess: ['p_room_id', 'p_guess'],
  advance_game_clock: ['p_room_id'],
  leave_game_room: ['p_room_id']
}

export function validateAction(action, args) {
  const expected = definitions[action]
  if (!expected) throw new TypeError('Unsupported game action.')
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new TypeError('Invalid action arguments.')
  const received = Object.keys(args)
  if (received.length !== expected.length || expected.some(key => !Object.hasOwn(args, key))) throw new TypeError('Invalid action arguments.')
  const string = key => typeof args[key] === 'string'
  if ('p_room_id' in args && (!string('p_room_id') || !uuid.test(args.p_room_id))) throw new TypeError('Invalid room id.')
  if ('p_target' in args && (!string('p_target') || !uuid.test(args.p_target))) throw new TypeError('Choose a valid player.')
  if ('p_nickname' in args && (!string('p_nickname') || args.p_nickname.trim().length < 2 || args.p_nickname.trim().length > 18)) throw new TypeError('Your name must be 2 to 18 characters.')
  if (action === 'create_game_room' && !['classic', 'duel'].includes(args.p_mode)) throw new TypeError('Choose a game mode.')
  if (action === 'join_game_room' && (!string('p_code') || !/^[A-Z0-9]{5,7}$/i.test(args.p_code.trim()))) throw new TypeError('Enter a valid room code.')
  if (action === 'send_game_message' && (!string('p_body') || !args.p_body.trim() || args.p_body.length > 280)) throw new TypeError('Messages must be 1 to 280 characters.')
  if (action === 'submit_spy_guess' && (!string('p_guess') || !args.p_guess.trim() || args.p_guess.length > 80)) throw new TypeError('Your guess must be 1 to 80 characters.')
  return { action, args }
}

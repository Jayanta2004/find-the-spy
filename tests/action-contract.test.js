import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { validateAction } from '../app/api/game-action/contract.js'

describe('server game action contract', () => {
  it('allows only an explicitly listed room action and exact arguments', () => {
    assert.deepEqual(validateAction('get_game_state', { p_room_id: '123e4567-e89b-12d3-a456-426614174000' }), {
      action: 'get_game_state', args: { p_room_id: '123e4567-e89b-12d3-a456-426614174000' }
    })
    assert.throws(() => validateAction('drop_table', {}), /Unsupported/)
    assert.throws(() => validateAction('get_game_state', { p_room_id: '123e4567-e89b-12d3-a456-426614174000', p_secret: true }), /arguments/)
  })
  it('rejects invalid names, modes, room codes and UUIDs before calling Supabase', () => {
    assert.throws(() => validateAction('create_game_room', { p_nickname: 'x', p_mode: 'classic' }), /name/)
    assert.throws(() => validateAction('create_game_room', { p_nickname: 'Alex', p_mode: 'mock' }), /mode/)
    assert.throws(() => validateAction('join_game_room', { p_nickname: 'Alex', p_code: 'bad code' }), /room code/)
    assert.throws(() => validateAction('cast_game_vote', { p_room_id: 'nope', p_target: 'nope' }), /room id/)
  })
  it('enforces chat and guess payload size limits at the API boundary', () => {
    const room = '123e4567-e89b-12d3-a456-426614174000'
    assert.throws(() => validateAction('send_game_message', { p_room_id: room, p_body: 'x'.repeat(281) }), /Messages/)
    assert.throws(() => validateAction('submit_spy_guess', { p_room_id: room, p_guess: 'x'.repeat(81) }), /guess/)
  })
})

import { useEffect, useRef, useState } from 'react'
import { ArrowRight, Check, Clock3, Copy, Crown, Eye, Flag, LockKeyhole, MessageCircle, Send, Shield, Users } from 'lucide-react'
import { advanceGameClock, beginGameRound, castGameVote, closeRoom, getGameState, sendGameMessage, submitSpyGuess, subscribeRoom, touchGameRoom } from '../lib/supabase'

function VoteReveal({ round, players }) {
  if (!round?.vote_tally) return null
  const eligible = Math.max(0, (players?.length || 0) - 1)
  return <section className="vote-reveal" aria-label="Anonymous vote tally"><div className="panel-head"><span>ANONYMOUS VOTE TALLY</span><small>{round.votes_cast} / {eligible} AGENT VOTES</small></div>{round.vote_tally.map(row=><div className="vote-tally-row" key={row.player_id}><span>{row.nickname}</span><b>{row.votes} {row.votes===1?"vote":"votes"}</b></div>)}</section>
}
const secondsLeft = deadline => Math.max(0, Math.ceil((new Date(deadline).getTime() - Date.now()) / 1000))
export default function GameRoom({ roomId, onLeave, nicknameAdjusted = false }) {
  const [game, setGame] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [guess, setGuess] = useState('')
  const [remaining, setRemaining] = useState(0)
  const [copied, setCopied] = useState(false)
  const [closing, setClosing] = useState(false)
  const advancing = useRef(false)
  const chatEnd = useRef(null)

  const refresh = async () => {
    try { const state = await getGameState(roomId); setGame(state); setError('') }
    catch (e) { const message=e.message || 'Could not load this room.'; if (/expired|room access denied|room not found|no longer available/i.test(message)) { setGame(null); onLeave(true, 'This room expired or is no longer available.') } else setError(message) }
    finally { setLoading(false) }
  }
  useEffect(() => {
    refresh()
    const stop = subscribeRoom(roomId, refresh)
    let stopped=false
    const heartbeat=async()=>{ try { await touchGameRoom(roomId); if(!stopped) await refresh() } catch(e) { const message=e.message||''; if(/expired|room access denied|room not found|no longer available/i.test(message)){ setGame(null); onLeave(true,'This room expired or is no longer available.') } else setError(message) } }
    const timer=setInterval(heartbeat,15000)
    const recover=()=>{ if(document.visibilityState==='visible') heartbeat() }
    window.addEventListener('online',recover)
    document.addEventListener('visibilitychange',recover)
    return ()=>{ stopped=true; clearInterval(timer); window.removeEventListener('online',recover); document.removeEventListener('visibilitychange',recover); stop() }
  }, [roomId])
  useEffect(() => { chatEnd.current?.scrollIntoView({ behavior: 'smooth' }) }, [game?.messages?.length])
  useEffect(() => {
    if (!game?.phase_deadline) { setRemaining(0); return }
    const tick = async () => {
      const left = secondsLeft(game.phase_deadline)
      setRemaining(left)
      if (left === 0 && !advancing.current) {
        advancing.current = true
        try { setGame(await advanceGameClock(roomId)) } catch (e) { setError(e.message || 'Could not advance the phase.') }
        finally { advancing.current = false }
      }
    }
    tick()
    const interval = setInterval(tick, 500)
    return () => clearInterval(interval)
  }, [roomId, game?.phase_deadline, game?.phase])

  async function action(fn) {
    setError(''); setBusy(true)
    try { const result = await fn(); if (result) setGame(result); else await refresh() }
    catch (e) { setError(e.message || 'That action could not be completed.') }
    finally { setBusy(false) }
  }
  async function closeLobby() { if (!window.confirm('Close this lobby for everyone? The room and its memberships will be removed.')) return; setClosing(true); try { await closeRoom(roomId); onLeave(true) } catch (e) { setError(e.message || 'Could not close the room.') } finally { setClosing(false) } }
  async function copyCode() {
    try { await navigator.clipboard.writeText(game.code); setCopied(true); setTimeout(() => setCopied(false), 1400) }
    catch { setError('Select the room code to copy it.') }
  }
  const me = game?.players?.find(p => p.is_me)
  const round = game?.round
  const isHost = me?.id === game?.host_user_id
  const isSpy = round?.role === 'spy'
  const modeMin = game?.mode === 'duel' ? 2 : 3
  const canStart = game?.players?.length >= modeMin && game?.players?.length <= (game?.max_players || 8)
  const heading = ({ investigation: 'Investigation', voting: 'Private vote', spy_guess: 'One last guess', round_results: 'Round debrief', finished: 'Final leaderboard' })[game?.phase] || 'The room is ready'
  const pad = n => String(n).padStart(2, '0')

  if (loading && !game) return <section className="game-shell game-loading" aria-busy="true" aria-label="Restoring game room"><div className="loading-orbit" aria-hidden="true"/><div><h2>Restoring your room</h2><p>Loading your role and current game phase�</p></div></section>
  if (!game) return <section className="game-shell"><div className="error" role="alert"><span>{error || 'This room could not be loaded.'}</span><button type="button" aria-label="Try loading the room again" onClick={refresh}>Try again</button></div></section>

  return <section className="game-shell" aria-label="Game room">
    <div className="game-topline"><span className="game-live"><i/> {game?.status === 'lobby' ? 'ROOM OPEN' : game?.status === 'finished' ? 'GAME COMPLETE' : 'LIVE GAME'}</span><button className="game-leave" type="button" aria-label="Leave room" disabled={game?.phase !== 'lobby' && game?.phase !== 'finished'} onClick={() => onLeave()}>Leave room <span>×</span></button></div>
    <div className="game-heading"><div><div className="game-kicker">{game?.mode === 'duel' ? 'SPY DUEL' : 'CLASSIC'} <span>/</span> {game?.phase === 'lobby' ? 'BRIEFING' : `ROUND ${game?.round_no} OF 3`}</div><h2>{heading}{game?.phase === 'investigation' && <small>Keep your questions sharp.</small>}</h2></div>{game?.phase_deadline&&<div className={`countdown ${remaining<=10?'urgent':''}`} role="timer" aria-label={`${remaining} seconds remaining`} aria-live="off"><Clock3 size={17} aria-hidden="true"/><span>{pad(Math.floor(remaining/60))}:{pad(remaining%60)}</span></div>}</div>

    {nicknameAdjusted&&game?.phase==='lobby'&&<div className="nickname-note">That name was already in the room, so you joined as <strong>{me?.nickname}</strong>.</div>}{game?.phase === 'lobby' ? <div className="briefing-grid"><article className="briefing-card"><div className="game-kicker">YOUR INVITATION</div><button className="invite-code" type="button" aria-label={`Copy room code ${game.code}`} onClick={copyCode}>{game.code}<Copy size={16}/></button><small className="hint">{copied?'Copied to clipboard':'Share this code with your players'}</small><div className="briefing-rule"><LockKeyhole size={16}/><span>Roles and the secret place are assigned privately when the game begins.</span></div></article><article className="roster-card"><div className="roster-title"><span><Users size={15}/> PLAYERS</span><span>{game.players?.length || 0} / {game.max_players}</span></div>{game.players?.map((p,i)=><div className="roster-person" key={p.id}><span className="roster-avatar">{p.nickname?.[0]?.toUpperCase()}</span><span>{p.nickname}{p.is_me&&<small> YOU</small>}</span>{p.id===game.host_user_id&&<b><Crown size={12}/> HOST</b>}</div>)}<div className="start-area">{isHost ? <><div className="host-actions"><button className="game-primary" disabled={!canStart||busy} onClick={()=>action(()=>beginGameRound(roomId))}>{busy?'Starting…':'Start the game'} <ArrowRight size={16}/></button><small>{canStart?'Three rounds. One hidden Spy.':`Need ${Math.max(0,modeMin-(game.players?.length||0))} more player${modeMin-(game.players?.length||0)===1?'':'s'} to start.`}</small>{isHost&&game.phase==='lobby'&&<button className="close-room" disabled={closing} onClick={closeLobby}>{closing?'Closing…':'Close lobby'}</button>}</div></> : <div className="await-host"><span className="pulse-dot"/> Waiting for the host to start</div>}</div></article></div> : null}

    {game?.phase && game.phase !== 'lobby' ? <>
      {game.phase !== 'finished' && <div className={`role-card ${isSpy?'spy':''}`}><div className="role-emblem">{isSpy?<Eye size={19}/>:<Shield size={19}/>}</div><div><span>{isSpy?'YOUR ROLE: THE SPY':'YOUR ROLE: AGENT'}</span><strong>{isSpy?`Category: ${round?.category}`:`Location: ${round?.location}`}</strong><small>{isSpy?'Blend in. Work out the exact place.':'Ask carefully. Find the Spy without giving away the place.'}</small></div><LockKeyhole size={16} className="role-lock"/></div>}
      {game.phase === 'investigation' && <div className="play-grid"><article className="chat-card"><div className="panel-head"><span><MessageCircle size={15}/> INVESTIGATION CHAT</span><small>{remaining>0?'90 SECOND WINDOW':'TIME UP'}</small></div><div className="chat-log" role="log" aria-label="Investigation chat" aria-live="polite" aria-relevant="additions">{game.messages?.length ? game.messages.map(m=><div className={`chat-message ${m.user_id===me?.id?'mine':''}`} key={m.id}><span className="chat-avatar">{m.nickname?.[0]?.toUpperCase()}</span><div><b>{m.nickname}{m.user_id===me?.id?' · YOU':''}</b><p>{m.body}</p><small>{new Date(m.created_at).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}</small></div></div>) : <div className="chat-empty">The room is quiet. Start with a good question.</div>}<div ref={chatEnd}/></div><form className="chat-compose" onSubmit={e=>{e.preventDefault();if(!message.trim())return;const text=message.trim();setMessage('');action(()=>sendGameMessage(roomId,text))}}><input aria-label="Write a chat message" value={message} maxLength={280} onChange={e=>setMessage(e.target.value)} placeholder="Ask the room something…" disabled={remaining===0||busy}/><button aria-label="Send message" disabled={remaining===0||busy||!message.trim()}><Send size={16}/></button></form></article><aside className="side-card"><div className="panel-head"><span><Users size={15}/> IN THE ROOM</span><small>{game.players?.length} PLAYERS</small></div>{game.players?.map(p=><div className="mini-player" key={p.id}><i>{p.nickname?.[0]?.toUpperCase()}</i><span>{p.nickname}{p.is_me?' (you)':''}</span><small>{p.score} pts</small></div>)}<div className="tip-box"><b>FIELD NOTE</b><p>Ask about details only someone who has been there would know. Keep it casual.</p></div></aside></div>}

      {game.phase === 'voting' && <div className="vote-layout"><div className="phase-callout"><div className="vote-mark"><Flag size={20}/></div><h3>Who’s the Spy?</h3><p>{isSpy?'Stay composed. The Agents are making their choice.':'Cast your private vote before the clock runs out.'}</p><small>Votes stay hidden until the phase ends.</small></div><div className="vote-list">{isSpy ? <div className="await-votes"><span className="pulse-dot"/> The Agents are voting privately…</div> : game.players?.filter(p=>!p.is_me).map(p=><button type="button" aria-pressed={round?.my_vote===p.id} className={`vote-choice ${round?.my_vote===p.id?'chosen':''}`} disabled={busy||remaining===0} key={p.id} onClick={()=>action(()=>castGameVote(roomId,p.id))}><span className="roster-avatar">{p.nickname?.[0]?.toUpperCase()}</span><span>{p.nickname}</span><span className="vote-radio">{round?.my_vote===p.id?'VOTED':'VOTE'}</span></button>)}<div className="vote-footnote">{isSpy?'Your role does not cast an Agent vote.':'You can change your vote until the timer ends.'}</div></div></div>}

      {game.phase === 'spy_guess' && <><VoteReveal round={round} players={game.players}/><div className="guess-layout"><div className="guess-copy"><div className="game-kicker">THE SPY HAS BEEN FOUND</div><h3>{isSpy?'Name the exact location.':'The Spy gets one final chance.'}</h3><p>{isSpy?`You know the category is ${round?.category}. Can you identify the exact place?`:'If the Spy guesses the location, they steal the round.'}</p></div>{isSpy?<form className="guess-form" onSubmit={e=>{e.preventDefault();if(guess.trim())action(()=>submitSpyGuess(roomId,guess.trim()))}}><label htmlFor="spy-guess">YOUR LOCATION GUESS</label><input id="spy-guess" value={guess} onChange={e=>setGuess(e.target.value)} maxLength={80} placeholder="Name the exact place…"/><button className="game-primary" disabled={!guess.trim()||busy||remaining===0}>{busy?'Submitting…':'Lock in my guess'} <ArrowRight size={16}/></button></form>:<div className="await-votes"><span className="pulse-dot"/> Waiting for the Spy to guess…</div>}</div></>}

      {(game.phase === 'round_results'||game.phase === 'finished') && <div className="results-layout"><div className="result-banner"><span className="result-symbol">{round?.outcome==='spy_escaped'||round?.spy_guess_correct?'◉':'✓'}</span><div><div className="game-kicker">{game.phase==='finished'?'THREE ROUNDS COMPLETE':'ROUND '+game.round_no+' COMPLETE'}</div><h3>{round?.outcome==='spy_escaped'?'The Spy stayed hidden.':round?.spy_guess_correct?'The Spy guessed the location.':'The Agents caught the Spy.'}</h3><p>The location was <strong>{round?.location}</strong> · {round?.category}</p>{round?.spy_guess&&<small>The Spy guessed: “{round.spy_guess}” {round.spy_guess_correct?'— exactly right.':'— not quite.'}</small>}</div></div><VoteReveal round={round} players={game.players}/><div className="leaderboard"><div className="panel-head"><span>{game.phase==='finished'?'FINAL LEADERBOARD':'SCOREBOARD'}</span><small>{game.phase==='finished'?'ALL 3 ROUNDS':'AFTER ROUND '+game.round_no}</small></div>{[...(game.players||[])].sort((a,b)=>b.score-a.score).map((p,i)=><div className="leader-row" key={p.id}><strong>{String(i+1).padStart(2,'0')}</strong><span className="roster-avatar">{p.nickname?.[0]?.toUpperCase()}</span><span>{p.nickname}{p.is_me?' (you)':''}{p.nickname===round?.spy_nickname&&<small> SPY THIS ROUND</small>}</span><b>{p.score}<small> PTS</small></b></div>)}</div>{game.phase==='round_results'&&isHost&&<button className="game-primary next-round" disabled={busy} onClick={()=>action(()=>beginGameRound(roomId))}>{busy?'Loading…':`Start round ${game.round_no+1}`} <ArrowRight size={16}/></button>}{game.phase==='round_results'&&!isHost&&<div className="await-host"><span className="pulse-dot"/> Waiting for the host to continue</div>}{game.phase==='finished'&&<button className="game-primary next-round" onClick={() => onLeave()}>Return to the lobby <ArrowRight size={16}/></button>}</div>}
    </> : null}
    {error&&<div className="error" role="alert"><span>{error}</span><button type="button" aria-label="Dismiss message" onClick={()=>setError('')}>×</button></div>}
    {game&&<div className="game-foot"><LockKeyhole size={13}/> Roles and locations are sent privately. Game state and timers are validated by the server.</div>}
  </section>
}




'use client'

﻿import { useEffect, useState } from 'react'
import { ArrowRight, Copy, Eye, Fingerprint, LockKeyhole, Radio, Shield, Users, X } from 'lucide-react'
import { backendReady, createRoom, joinRoom, leaveRoom, resumeRoom } from '../lib/supabase'
import GameRoom from './GameRoom.jsx'

function explainError(error, fallback) {
  const message = error?.message || fallback
  if (/room is full/i.test(message)) return 'This room is full. Ask the host for another invite.'
  if (/expired/i.test(message)) return 'This room has expired. Create or join a new room.'
  if (/too many actions/i.test(message)) return 'That was a lot of activity. Wait a moment, then try again.'
  if (/room not found/i.test(message)) return 'We couldn’t find that room. Check the code and try again.'
  return message
}

export default function App() {
  const [name, setName] = useState('')
  const [code, setCode] = useState('')
  const [mode, setMode] = useState('classic')
  const [room, setRoom] = useState(null)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [restoring, setRestoring] = useState(Boolean(backendReady))
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    const savedName = window.sessionStorage.getItem('spy-name')
    if (savedName) setName(savedName)
  }, [])

  useEffect(() => {
    let live = true
    if (!backendReady) return () => { live = false }
    resumeRoom()
      .then(active => { if (live && active?.id) setRoom(active) })
      .catch(e => { if (live) setError(explainError(e, 'Could not restore your room. Check your connection and refresh.')) })
      .finally(() => { if (live) setRestoring(false) })
    return () => { live = false }
  }, [])

  async function act(kind, event) {
    event?.preventDefault()
    setError('')
    setNotice('')
    const nickname = name.trim()
    if (nickname.length < 2 || nickname.length > 18) return setError('Your field name must be between 2 and 18 characters.')
    if (kind === 'join' && !/^[A-Z0-9]{5,7}$/.test(code)) return setError('Enter a valid room code with 5 to 7 letters or numbers.')
    if (!backendReady) return setError('Shared rooms are not connected yet. Complete the Supabase setup before creating or joining a room.')
    setBusy(true)
    try {
      sessionStorage.setItem('spy-name', nickname)
      const active = kind === 'create' ? await createRoom(nickname, mode) : await joinRoom(nickname, code)
      setRoom(active)
    } catch (e) {
      setError(explainError(e, 'Could not connect to that room. Check your connection and try again.'))
    } finally {
      setBusy(false)
    }
  }

  async function leaveCurrentRoom(alreadyClosed = false, message = '') {
    try {
      if (!alreadyClosed) await leaveRoom(room.id)
      setRoom(null)
      setError('')
      setNotice(message)
    } catch (e) {
      setError(explainError(e, 'Could not leave the room.'))
    }
  }

  async function copyCode() {
    try {
      await navigator.clipboard.writeText(room.code)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1500)
    } catch {
      setError('Copy is unavailable here. Select the room code to share it.')
    }
  }

  return <main className="shell">
    <header className="nav">
      <a className="wordmark" href="#home" aria-label="Find the Spy home"><span className="brand-icon"><Eye size={16} aria-hidden="true"/></span> FIND THE SPY</a>
      <div className="nav-label"><i aria-hidden="true"/> A SOCIAL DEDUCTION GAME <span className="help" aria-hidden="true">?</span></div>
    </header>

    {notice && <div className="room-notice" role="status">{notice}</div>}
    {restoring && <div className="restore-status" role="status" aria-live="polite"><span className="loading-dot"/> Restoring your room…</div>}

    <section className="hero" id="home" aria-labelledby="hero-title">
      <div className="hero-text">
        <div className="eyebrow"><b aria-hidden="true"/> A QUICK GAME FOR YOUR GROUP</div>
        <h1 id="hero-title">One place.<br/>One hidden <em>Spy.</em></h1>
        <p>Most players know the secret location.<br/>The Spy has to blend in and figure it out.</p>
        <div className="caption"><span aria-hidden="true">✳</span> Ask questions, read the room, and vote together.</div>
      </div>
      <div className="illustration" role="img" aria-label="A classified location map with a hidden target">
        <div className="grid"/><div className="orbit orbit-a"/><div className="orbit orbit-b"/><div className="orbit orbit-c"/><div className="target"/>
        <div className="coords" aria-hidden="true">37° 46' 49.3&quot; N<br/>122° 25' 09.6&quot; W</div>
        <div className="classified"><b aria-hidden="true"/> LOCATION CLASSIFIED</div><div className="frame-no">01 <small>/ 03</small></div>
        <div className="stamp" aria-hidden="true">TRUST<br/><span>×</span><br/>NO ONE</div><div className="art-foot">SOMEWHERE IN PLAIN SIGHT</div>
      </div>
    </section>

    <section className="section" aria-labelledby="join-heading">
      <div className="section-head"><span aria-hidden="true">01</span><h2 id="join-heading">Get a game going</h2><small>NO ACCOUNT NEEDED</small></div>
      <div className="cards">
        <form className="card" onSubmit={e => act('create', e)}>
          <div className="card-kicker"><span aria-hidden="true">↗</span> YOU?RE THE HOST</div>
          <h3>Host a game</h3><p className="muted">Choose a mode, then share your room code.</p>
          <label htmlFor="create-name">YOUR NAME <small>2 TO 18 CHARACTERS</small></label>
          <div className="input"><Fingerprint size={16} aria-hidden="true"/><input id="create-name" value={name} minLength={2} maxLength={18} required autoComplete="nickname" onChange={e => setName(e.target.value)} placeholder="e.g. Alex" disabled={busy}/></div>
          <div className="mode-row"><span className="mode-label" id="mode-label">CHOOSE YOUR GAME</span><small>3–8 PLAYERS / 2 IN DUEL</small></div>
          <div className="mode-options" role="radiogroup" aria-labelledby="mode-label">
            <label className={'mode '+(mode==='classic'?'active':'')}>
              <input className="mode-radio" type="radio" name="game-mode" value="classic" checked={mode==='classic'} onChange={() => setMode('classic')} disabled={busy}/><i aria-hidden="true">{mode==='classic'&&<b/>}</i>
              <span><strong>Classic</strong><small>One Spy. Everyone else knows the place.</small></span><em>3–8</em>
            </label>
            <label className={'mode '+(mode==='duel'?'active':'')}>
              <input className="mode-radio" type="radio" name="game-mode" value="duel" checked={mode==='duel'} onChange={() => setMode('duel')} disabled={busy}/><i aria-hidden="true">{mode==='duel'&&<b/>}</i>
              <span><strong>Spy Duel</strong><small>A head-to-head game of deduction.</small></span><em>2</em>
            </label>
          </div>
          <button className="primary" type="submit" disabled={!backendReady||busy}>{busy ? <><span>Opening room…</span><span className="button-spinner" aria-hidden="true"/></> : <>Create a room <ArrowRight size={16} aria-hidden="true"/></>}</button>
          {!backendReady&&<div className="backend-note"><LockKeyhole size={14} aria-hidden="true"/> Backend setup required to enable rooms.</div>}
        </form>

        <form className="card join" onSubmit={e => act('join', e)}>
          <div className="card-kicker"><span aria-hidden="true">↙</span> JOIN YOUR FRIENDS</div>
          <h3>Join a game</h3><p className="muted">Use the room code your host shared with you.</p>
          <label htmlFor="join-name">YOUR NAME <small>2 TO 18 CHARACTERS</small></label>
          <div className="input"><Fingerprint size={16} aria-hidden="true"/><input id="join-name" value={name} minLength={2} maxLength={18} required autoComplete="nickname" onChange={e => setName(e.target.value)} placeholder="e.g. Alex" disabled={busy}/></div>
          <label className="room-label" htmlFor="room-code">ROOM CODE <small>ASK YOUR HOST</small></label>
          <div className="input code-input"><Radio size={16} aria-hidden="true"/><input id="room-code" value={code} minLength={5} maxLength={7} required autoComplete="off" spellCheck="false" onChange={e => setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g,''))} placeholder="e.g. K7M2Q" disabled={busy}/><small aria-hidden="true">{code.length}/7</small></div>
          <button className="secondary" type="submit" disabled={!backendReady||busy}>{busy ? <><span>Joining room…</span><span className="button-spinner" aria-hidden="true"/></> : <>Join the room <ArrowRight size={16} aria-hidden="true"/></>}</button>
          <div className="privacy"><Shield size={15} aria-hidden="true"/> No account or password needed.</div>
        </form>
      </div>
      {error&&<div className="error" role="alert"><span>{error}</span><button type="button" aria-label="Dismiss message" onClick={() => setError('')}><X size={15} aria-hidden="true"/></button></div>}
    </section>

    {room&&<GameRoom key={room.id} roomId={room.id} onLeave={leaveCurrentRoom} nicknameAdjusted={room.nickname_adjusted}/>}

    <section className="section how" aria-labelledby="how-heading">
      <div className="section-head"><span aria-hidden="true">02</span><h2 id="how-heading">How to play</h2><small>READY IN A MINUTE</small></div>
      <div className="steps">
        {[['01','◉','Join the room','Create a room or enter your host?s code. Choose Classic or Spy Duel.'],['02','◍','Ask around','Agents know the place. The Spy only knows its category. Keep the chat casual.'],['03','◇','Call the Spy','After the discussion, vote privately. If caught, the Spy gets one last guess.']].map(step=><article className="step" key={step[0]}><small>{step[0]}</small><div aria-hidden="true">{step[1]}</div><h3>{step[2]}</h3><p>{step[3]}</p></article>)}
      </div>
    </section>
    <footer><a className="wordmark footer-brand" href="#home"><span className="brand-icon"><Eye size={14} aria-hidden="true"/></span> FIND THE SPY</a><span>KEEP YOUR EYES OPEN. YOUR MOUTH CLOSED.</span><span>© FIND THE SPY 2026</span></footer>
  </main>
}

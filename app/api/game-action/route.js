import { createClient } from '@supabase/supabase-js'
import { validateAction } from './contract.js'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

function json(data, status = 200) {
  return Response.json(data, { status, headers: { 'Cache-Control': 'no-store' } })
}

export async function POST(request) {
  if (!supabaseUrl || !anonKey || supabaseUrl.includes('YOUR_PROJECT_ID') || anonKey.includes('YOUR_SUPABASE')) {
    return json({ error: 'The shared game backend is not configured yet.' }, 503)
  }
  const authorization = request.headers.get('authorization') || ''
  const token = authorization.match(/^Bearer\s+([^\s]+)$/i)?.[1]
  if (!token) return json({ error: 'Your guest session is missing. Refresh and try again.' }, 401)

  let input
  try {
    const text = await request.text()
    if (text.length > 4096) return json({ error: 'That request is too large.' }, 413)
    input = JSON.parse(text)
  } catch {
    return json({ error: 'The request could not be read.' }, 400)
  }

  let action
  try { action = validateAction(input?.action, input?.args) }
  catch (error) { return json({ error: error.message }, 400) }

  const client = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: `Bearer ${token}` } }
  })

  const { data: authData, error: authError } = await client.auth.getUser(token)
  if (authError || !authData?.user) return json({ error: 'Your guest session has expired. Refresh and try again.' }, 401)

  const { data, error } = await client.rpc(action.action, action.args)
  if (error) {
    const status = /too many actions/i.test(error.message) ? 429 : error.code === '23505' ? 409 : error.code?.startsWith('PGRST') ? 400 : 400
    return json({ error: error.message || 'That action could not be completed.' }, status)
  }
  return json({ data })
}

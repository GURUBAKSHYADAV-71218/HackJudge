import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3"
import * as jose from "https://deno.land/x/jose@v4.14.4/index.ts"

const allowedOrigins = new Set(
  (Deno.env.get('APP_ALLOWED_ORIGINS') ?? '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),
)

function headersFor(origin: string | null) {
  const headers: Record<string, string> = {
    'Vary': 'Origin',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  }
  if (origin && allowedOrigins.has(origin)) {
    headers['Access-Control-Allow-Origin'] = origin
  }
  return headers
}

function jsonResponse(body: Record<string, unknown>, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    headers: { ...headersFor(origin), 'Content-Type': 'application/json' },
    status,
  })
}

function getClientIp(req: Request) {
  // Supabase's Edge gateway supplies the forwarded client IP. Do not fall back
  // to a request body, query parameter, or arbitrary custom header.
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
  if (!ip || ip.length > 64 || !/^[0-9a-fA-F:.]+$/.test(ip)) return null
  return ip
}

async function hashClientIp(ip: string, hmacSecret: string) {
  const encoder = new TextEncoder()
  if (encoder.encode(hmacSecret).byteLength < 32) throw new Error('Rate-limit HMAC secret must be at least 32 bytes')
  const key = await crypto.subtle.importKey(
    'raw', encoder.encode(hmacSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  )
  const digest = await crypto.subtle.sign('HMAC', key, encoder.encode(ip))
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

async function readBoundedBody(req: Request) {
  const contentLength = Number(req.headers.get('content-length') || 0)
  if (contentLength > 1024 || !req.body) return null

  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let totalBytes = 0
  while (true) {
    const { value, done } = await reader.read()
    if (done) break
    if (!value) continue
    totalBytes += value.byteLength
    if (totalBytes > 1024) {
      await reader.cancel()
      return null
    }
    chunks.push(value)
  }

  const body = new Uint8Array(totalBytes)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(body)
}

async function mintJudgeJwt(judge: { id: string, event_id: string, round_ids: string[], name: string }, jwtSecret: string) {
  const secret = new TextEncoder().encode(jwtSecret)
  return new jose.SignJWT({
    role: 'authenticated',
    judge_id: judge.id,
    event_id: judge.event_id,
    round_ids: judge.round_ids,
    name: judge.name,
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setIssuer('supabase')
    .setExpirationTime('7d')
    .sign(secret)
}

serve(async (req) => {
  const origin = req.headers.get('origin')

  if (origin && !allowedOrigins.has(origin)) {
    return jsonResponse({ error: 'Origin not allowed' }, 403, null)
  }

  if (req.method === 'OPTIONS') {
    const headers = headersFor(origin)
    headers['Access-Control-Allow-Headers'] = 'authorization, x-client-info, apikey, content-type'
    headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
    headers['Access-Control-Max-Age'] = '600'
    return new Response(null, { headers, status: 204 })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405, origin)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    const jwtSecret = Deno.env.get('SUPABASE_JWT_SECRET')
    const rateLimitHmacSecret = Deno.env.get('INVITE_RATE_LIMIT_HMAC_SECRET')
    if (!supabaseUrl || !supabaseServiceRoleKey || !jwtSecret || !rateLimitHmacSecret || allowedOrigins.size === 0) {
      throw new Error('Required function configuration is missing')
    }

    const clientIp = getClientIp(req)
    if (!clientIp) return jsonResponse({ error: 'Unable to resolve invitation' }, 400, origin)

    // Initialize Supabase with service role to bypass RLS for token lookup
    const supabase = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    // Persistent, atomic per-IP limiting works across Edge Function isolates.
    // Fail closed if the rate-limit store is unavailable.
    const clientIpHash = await hashClientIp(clientIp, rateLimitHmacSecret)
    const { data: allowed, error: rateLimitError } = await supabase.rpc('allow_invite_resolution', {
      target_client_ip_hash: clientIpHash,
    })
    if (rateLimitError) throw rateLimitError
    if (!allowed) {
      return new Response(JSON.stringify({ error: 'Too many invitation attempts. Try again shortly.' }), {
        headers: { ...headersFor(origin), 'Content-Type': 'application/json', 'Retry-After': '60' },
        status: 429,
      })
    }

    const bodyText = await readBoundedBody(req)
    if (!bodyText) return jsonResponse({ error: 'Invalid or expired invitation' }, 400, origin)
    let body: Record<string, unknown>
    try {
      body = JSON.parse(bodyText)
    } catch {
      return jsonResponse({ error: 'Invalid or expired invitation' }, 400, origin)
    }
    const refreshJwt = body?.refresh_jwt
    if (typeof refreshJwt === 'string') {
      if (refreshJwt.length > 4096) return jsonResponse({ error: 'Judge session expired. Open your invitation link again.' }, 401, origin)
      try {
        const { payload } = await jose.jwtVerify(refreshJwt, new TextEncoder().encode(jwtSecret), { issuer: 'supabase' })
        if (typeof payload.judge_id !== 'string') throw new Error('Missing judge identity')
        const { data: activeJudge, error: judgeError } = await supabase
          .from('judges')
          .select('id, event_id, round_ids, name')
          .eq('id', payload.judge_id)
          .eq('status', 'active')
          .maybeSingle()
        if (judgeError || !activeJudge) throw new Error('Judge is not active')
        const jwt = await mintJudgeJwt(activeJudge, jwtSecret)
        return jsonResponse({ jwt, judge_id: activeJudge.id, event_id: activeJudge.event_id, name: activeJudge.name }, 200, origin)
      } catch {
        return jsonResponse({ error: 'Judge session expired. Open your invitation link again.' }, 401, origin)
      }
    }

    const token = body?.token
    if (typeof token !== 'string' || !/^[a-f0-9]{36}$/.test(token)) {
      return jsonResponse({ error: 'Invalid or expired invitation' }, 400, origin)
    }

    // Atomically rotate the invitation token, so the same link cannot create
    // multiple sessions from concurrent requests.
    const { data: rows, error: consumeError } = await supabase.rpc('consume_judge_invite', {
      invite_token_value: token,
    })

    if (consumeError) throw consumeError
    const judge = rows?.[0]
    if (!judge) {
      return jsonResponse({ error: 'Invalid or expired invitation' }, 404, origin)
    }

    // These custom JWTs authenticate PostgREST only; the frontend uses a
    // dedicated accessToken client and never submits them to GoTrue /user.
    const jwtString = await mintJudgeJwt(judge, jwtSecret)

    return jsonResponse({
        jwt: jwtString, 
        judge_id: judge.id,
        event_id: judge.event_id,
        name: judge.name
      }, 200, origin)
  } catch (_error) {
    return jsonResponse({ error: 'Unable to resolve invitation' }, 500, origin)
  }
})

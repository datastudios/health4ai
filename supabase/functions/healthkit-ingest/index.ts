// HealthKit Bridge — Supabase Edge Function: healthkit-ingest
// Receives batched HealthKit samples from the iOS app and upserts into public.healthkit_metrics
// Deploy: supabase functions deploy healthkit-ingest
//
// Upsert key: (user_id, metric_type, source_device, started_at) — the key supabase/bootstrap/001
// creates. It used to be (user_id, metric_type, started_at), which matched only the legacy
// production project; against every bootstrap project each upsert failed with 42P10 "no unique
// or exclusion constraint matching the ON CONFLICT specification", so a new user's sync could
// never write a row. Register D353.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

interface HealthSample {
  metric_type: string
  value: number | null
  unit: string
  source_device: string
  started_at: string
  ended_at: string | null
  metadata: Record<string, unknown> | null
}

interface IngestPayload {
  samples: HealthSample[]
}

const MAX_BODY_BYTES = 5 * 1024 * 1024
const MAX_METADATA_BYTES = 4 * 1024
const HOUR_MS = 3_600_000

// Merged hourly totals. For activity types that several devices record at the same moment, the
// app sends HealthKit's merged sum per UTC hour under this source label instead of each
// device's samples, because summing both devices counted the same steps twice (+67% across
// 2021 on real data). Such an hour must REPLACE that hour's per-device rows, or it is summed
// on top of them; health4ai_replace_merged_hours does both in one transaction. Register D361.
// Keep in step with HealthKitManager.allSourcesLabel / doubleCountedActivityIdentifiers (iOS)
// and DOUBLE_COUNTED_ACTIVITY_TYPES (scripts/import_health_export.py).
const MERGED_SOURCE = 'HealthKit (all sources)'
const MERGED_HOUR_TYPES = new Set([
  'HKQuantityTypeIdentifierStepCount',
  'HKQuantityTypeIdentifierDistanceWalkingRunning',
  'HKQuantityTypeIdentifierDistanceCycling',
  'HKQuantityTypeIdentifierDistanceSwimming',
  'HKQuantityTypeIdentifierDistanceWheelchair',
  'HKQuantityTypeIdentifierDistanceDownhillSnowSports',
  'HKQuantityTypeIdentifierPushCount',
  'HKQuantityTypeIdentifierSwimmingStrokeCount',
  'HKQuantityTypeIdentifierFlightsClimbed',
  'HKQuantityTypeIdentifierActiveEnergyBurned',
  'HKQuantityTypeIdentifierBasalEnergyBurned',
  'HKQuantityTypeIdentifierAppleExerciseTime',
  'HKQuantityTypeIdentifierAppleMoveTime',
  'HKQuantityTypeIdentifierAppleStandTime',
])

// Reported on EVERY 2xx, including the empty batch the app sends to ask. An older deployment of
// this function would store merged hours WITHOUT deleting the per-device rows, which is worse than
// not merging at all, so the app sends them only to a server that lists this.
const CAPABILITIES = ['merged_hours_v1']

// A merged row's timestamps decide which rows are DELETED, so JavaScript and Postgres must read them
// as the same instant. Date.parse does not guarantee that: it truncates past milliseconds, where
// Postgres keeps microseconds, and it puts two-digit years 50-99 in the 1900s where Postgres puts
// 00-69 in the 2000s. Either lets the hour check pass on one instant while the delete runs on
// another. Merged rows therefore need a strict ISO-8601 form, and the function receives the
// canonical toISOString() of the checked instant rather than the client's string. (Security
// review 2026-09-13.)
const STRICT_ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 })
  }

  // Fast path only: a Content-Length that is present and too large is refused before any work.
  // A MISSING header is not refused. The iOS app sends one (httpBody is Data), but HTTP/2 does not
  // require it and a gateway hop may not forward it, and refusing on absence alone would turn that
  // into a total sync outage with no retry (the app does not retry 4xx). The real limit is enforced
  // on the bytes that actually arrive, in readBodyCapped, which also closes the gap where a small
  // declared length could front a much larger body.
  const contentLengthHeader = req.headers.get('content-length')
  if (contentLengthHeader !== null) {
    const contentLength = Number(contentLengthHeader)
    if (!Number.isFinite(contentLength) || contentLength > MAX_BODY_BYTES) {
      // Release the body before answering. Responding with it unread made a buffering gateway
      // report the upstream as broken: an oversized request came back 502 instead of this 413
      // (measured on a local Supabase stack, 2026-09-12).
      await releaseBody(req.body)
      return json({ error: 'Request body exceeds maximum size' }, 413)
    }
  }

  // Validate Supabase JWT
  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) {
    return json({ error: 'Missing Authorization header' }, 401)
  }
  const bearer = authHeader.slice(7)

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${bearer}` } },
  })
  const { data: { user }, error: authError } = await userClient.auth.getUser()
  if (authError || !user) return json({ error: 'Unauthorized' }, 401)
  const userId = user.id

  // Parse payload
  // Read at most MAX_BODY_BYTES of what actually arrives, whatever the headers said.
  const bodyText = await readBodyCapped(req, MAX_BODY_BYTES)
  if (bodyText === null) {
    return json({ error: 'Request body exceeds maximum size' }, 413)
  }
  let payload: IngestPayload
  try {
    payload = JSON.parse(bodyText)
  } catch {
    return json({ error: 'Invalid JSON body' }, 400)
  }
  // JSON.parse accepts `null`, arrays and scalars. `null` used to crash on payload.samples (a 500),
  // and a top-level array returned 200 {inserted: 0}, a success report for input that wrote nothing.
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    return json({ error: 'Body must be a JSON object' }, 400)
  }

  if (!Array.isArray(payload.samples) || payload.samples.length === 0) {
    return json({ inserted: 0, capabilities: CAPABILITIES })
  }

  // Validate sample count (max 1000 per request)
  if (payload.samples.length > 1000) {
    return json({ error: 'Batch size exceeds maximum of 1000 samples' }, 400)
  }

  // Reject unbounded string fields (data integrity + storage cost guard)
  const MAX_STR = 256
  for (const s of payload.samples) {
    if (
      (s.metric_type?.length ?? 0) > MAX_STR ||
      (s.unit?.length ?? 0) > MAX_STR ||
      (s.source_device?.length ?? 0) > MAX_STR
    ) {
      return json({ error: 'String field exceeds maximum length of 256' }, 400)
    }
    // `!= null`, not `!== null`. The iOS app's HealthSample uses synthesized Codable, which OMITS a nil
    // optional rather than writing null, so a sample without metadata arrives with the key absent
    // (undefined). The strict check rejected every such sample with a 400, and one of them fails its
    // whole batch: in production, 2026-09-12, BasalEnergyBurned, DistanceWalkingRunning, WalkingSpeed
    // and every other metadata-less type stopped syncing the moment this deployed. Absent means null.
    if (s.metadata != null && (typeof s.metadata !== 'object' || Array.isArray(s.metadata))) {
      return json({ error: 'Metadata must be an object or null' }, 400)
    }
    if (s.metadata && new TextEncoder().encode(JSON.stringify(s.metadata)).length > MAX_METADATA_BYTES) {
      return json({ error: 'Metadata exceeds maximum size of 4096 bytes' }, 400)
    }
    // started_at is in both the unique key and the dedup key. new Date() on a malformed value
    // yields NaN, which collapses distinct samples onto one dedup entry, and a value Postgres
    // cannot cast fails the WHOLE batch with a 500. Reject the batch with a 400 instead.
    if (typeof s.started_at !== 'string' || s.started_at.length > 64 || Number.isNaN(Date.parse(s.started_at))) {
      return json({ error: 'started_at must be an ISO-8601 timestamp' }, 400)
    }
    if (s.ended_at != null && (typeof s.ended_at !== 'string' || s.ended_at.length > 64 || Number.isNaN(Date.parse(s.ended_at)))) {
      return json({ error: 'ended_at must be an ISO-8601 timestamp or null' }, 400)
    }
    // A merged row deletes every per-device row whose started_at falls in its hour, so its shape is
    // enforced rather than trusted: exactly one whole UTC hour, of a type that is merged at all.
    // Anything looser would let a malformed row delete a stretch of per-device data it does not
    // replace, or turn instantaneous readings like heart rate into a meaningless hourly sum.
    if (s.source_device === MERGED_SOURCE) {
      const start = Date.parse(s.started_at)
      if (
        !MERGED_HOUR_TYPES.has(s.metric_type) ||
        !STRICT_ISO_8601.test(s.started_at) ||
        start % HOUR_MS !== 0 ||
        typeof s.ended_at !== 'string' ||
        !STRICT_ISO_8601.test(s.ended_at) ||
        Date.parse(s.ended_at) !== start + HOUR_MS
      ) {
        return json({ error: 'Merged rows must cover exactly one UTC hour of a merged activity type' }, 400)
      }
      // A string, boolean or object value fails the whole transaction in Postgres as a 500, which the
      // app retries; the strings "NaN" and "Infinity" would be stored and poison every later sum.
      if (typeof s.value !== 'number' || !Number.isFinite(s.value)) {
        return json({ error: 'Merged rows must carry a finite numeric value' }, 400)
      }
    }
  }

  // Attach user_id to all rows
  const rows = payload.samples.map((s) => ({
    user_id: userId,
    metric_type: s.metric_type,
    value: s.value ?? null,
    unit: s.unit,
    // '' not null: source_device is part of the unique key, and NULL <> NULL would let two
    // NULL-device rows for one instant both insert instead of upserting. Bootstrap declares
    // the column NOT NULL DEFAULT ''. The iOS app always sends a string; other clients may not.
    source_device: s.source_device ?? '',
    started_at: s.started_at,
    ended_at: s.ended_at ?? null,
    metadata: s.metadata ?? null,
  }))

  // Deduplicate within the batch on the DB conflict key. user_id is constant per request, so
  // metric_type|source_device|started_at is the key. PostgreSQL UPSERT rejects intra-batch
  // duplicates ("cannot affect row a second time"). source_device IS in the key now: an Apple
  // Watch and an Oura Ring recording the same instant are two samples, and the old
  // metric_type|started_at dedup silently kept only the last one. Last write wins only for a
  // true duplicate from the same device.
  //
  // Normalize started_at to epoch ms before keying: iOS ISO8601DateFormatter with
  // .withInternetDateTime can produce "+00:00" or "-04:00" offset forms rather than "Z".
  // JS string comparison sees these as different; Postgres timestamptz normalizes them to
  // the same internal value — causing "cannot affect row a second time" on upsert.
  const seen = new Map<string, typeof rows[0]>()
  for (const row of rows) {
    const normTs = new Date(row.started_at).getTime()
    // JSON.stringify, not a '|'-joined string: neither field forbids '|', so
    // ("A|B","C") and ("A","B|C") joined the same way and one real sample was dropped.
    seen.set(JSON.stringify([row.metric_type, row.source_device, normTs]), row)
  }
  const dedupedRows = Array.from(seen.values())
  const deviceRows = dedupedRows.filter((r) => r.source_device !== MERGED_SOURCE)
  const mergedRows = dedupedRows.filter((r) => r.source_device === MERGED_SOURCE)

  let inserted = 0
  let replaced = 0

  if (deviceRows.length > 0) {
    // Use service role to bypass RLS for upsert (adminClient already defined above)
    const { error, count } = await adminClient
      .from('healthkit_metrics')
      .upsert(deviceRows, {
        onConflict: 'user_id,metric_type,source_device,started_at',
        ignoreDuplicates: false,
        count: 'exact',
      })
    if (error) {
      // Error code only; never row contents.
      console.error('Upsert failed', { code: error.code })
      return json({ error: 'Unable to store samples' }, 500)
    }
    inserted += count ?? deviceRows.length
  }

  if (mergedRows.length > 0) {
    // user_id comes from the verified JWT above, never from the body. The SQL function is
    // EXECUTE-able by the service role only, precisely because it takes a user_id parameter.
    const { data, error } = await adminClient.rpc('health4ai_replace_merged_hours', {
      p_user_id: userId,
      // Canonical timestamps: the instant that passed the hour check, not the client's spelling of it.
      p_rows: mergedRows.map(({ metric_type, value, unit, started_at, metadata }) => {
        const start = Date.parse(started_at)
        return {
          metric_type, value, unit, metadata,
          started_at: new Date(start).toISOString(),
          ended_at: new Date(start + HOUR_MS).toISOString(),
        }
      }),
    })
    const result = Array.isArray(data) ? data[0] : null
    if (error || !result) {
      // No result row is a failure, not zero: the function always returns exactly one.
      console.error('Merged hour replace failed', { code: error?.code ?? 'no_result' })
      return json({ error: 'Unable to store samples' }, 500)
    }
    inserted += Number(result.written_count)
    replaced += Number(result.deleted_count)
  }

  return json({ inserted, replaced, capabilities: CAPABILITIES })
})

/**
 * Cancels a body stream we are refusing. A cancel that rejects means the stream had already
 * failed; that is logged, never swallowed, and must not turn an intended 413 into a 500.
 */
async function releaseBody(stream: ReadableStream<Uint8Array> | ReadableStreamDefaultReader<Uint8Array> | null): Promise<void> {
  if (!stream) return
  try {
    await stream.cancel()
  } catch (err) {
    console.error('Request body cancel failed', { name: (err as Error)?.name })
  }
}

/** Reads the request body, refusing past `max` bytes as they arrive rather than after buffering it all. */
async function readBodyCapped(req: Request, max: number): Promise<string | null> {
  if (!req.body) return ''
  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > max) {
      await releaseBody(reader)
      return null
    }
    chunks.push(value)
  }
  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder().decode(bytes)
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

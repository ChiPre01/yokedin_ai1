# yokedin-media-api Worker

Cloudflare Worker for Yoked In's media API (R2) and Phase 2 AI endpoints
(Groq). Firebase Authentication remains the identity provider and Firestore
remains the database. The Worker verifies Firebase ID tokens and reads
`chats` / `groups` membership using the caller's token; it does not write to
Firestore.

The AI routes are additive. The existing media routes, R2 metadata, expiry
rules, and scheduled cleanup remain in `src/index.js`.

## Routes

| Route | Method | Authentication | Notes |
|---|---|---|---|
| `/health` | GET | None | Liveness probe |
| `/upload` | POST | Firebase ID token | R2 media upload |
| `/media/<key>` | GET / DELETE | Firebase ID token (`?authToken=` is allowed for GET only) | R2 media access |
| `/ai/summarize-chat` | POST | Firebase ID token | Caller must belong to the private chat or group |
| `/ai/generate-meeting-minutes` | POST | Firebase ID token | Caller must belong to the private chat or group |
| `/ai/smart-replies` | POST | Firebase ID token | Caller must belong to the private chat or group |

AI endpoints accept JSON only. Request bodies are limited to 64 KB. AI
endpoints do not access `MEDIA_BUCKET` and do not write to Firestore.

## AI request bodies

```json
{
  "conversationId": "...",
  "conversationType": "private",
  "conversationTitle": "...",
  "messages": ["Alice: ..."]
}
```

`POST /ai/summarize-chat` accepts `conversationType` as `private` or `group`,
and `messages` must contain 1–30 message strings.

```json
{
  "conversationId": "...",
  "conversationType": "group",
  "conversationTitle": "...",
  "rawContent": "...",
  "participantNames": {"firebase-uid": "Name"},
  "durationSeconds": 300
}
```

`POST /ai/generate-meeting-minutes` requires non-empty `rawContent` of at most
16,000 characters. `participantNames` and `durationSeconds` are optional.

```json
{
  "conversationId": "...",
  "conversationType": "private",
  "recentMessages": ["..."]
}
```

`POST /ai/smart-replies` accepts up to 10 recent message strings. An empty
`recentMessages` array returns an empty replies array without calling Groq.

## Authentication and authorization order

For each AI route, the Worker:

1. Verifies the Firebase ID token.
2. Reads and validates the JSON request body.
3. Validates the conversation ID and type.
4. Checks that the authenticated UID belongs to the specified chat or group.
5. Validates endpoint-specific message/notes fields.
6. Applies the per-user rate limit.
7. Calls Groq.

Invalid requests and users who are not members do not consume the AI request
limit. The rate-limit key is the verified Firebase UID (`user.sub`), never a
client-supplied UID.

## Responses and errors

Successful responses have HTTP `200` and contain `provider: "groq"`, the
model name, and the endpoint result (`summary`, `minute`, or `replies`).

AI errors use this shape:

```json
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "...",
    "retryAfterSeconds": 60
  }
}
```

Expected error codes include `INVALID_REQUEST`, `FORBIDDEN`, `RATE_LIMITED`,
`AI_RATE_LIMITER_UNAVAILABLE`, `AI_NOT_CONFIGURED`, `BAD_AI_RESPONSE`,
`AI_SERVICE_UNAVAILABLE`, `AI_TIMEOUT`, `NOT_FOUND`, and `INTERNAL`.
Media routes retain their existing media error response format.

## Groq secret

`GROQ_API_KEY` is the only new provider secret. Configure it in the Cloudflare
Worker settings as a **Secret**:

- Cloudflare dashboard -> Workers & Pages -> `yokedin-media-api` ->
  Settings -> Variables and Secrets -> Add -> Secret.
- Or use `npx wrangler secret put GROQ_API_KEY --name yokedin-media-api`.

The Worker reads the secret from `env.GROQ_API_KEY`, sends it only in the
Groq request authorization header, and does not log or return it. If it is
missing, authorized AI requests return `503 AI_NOT_CONFIGURED`.

For local development, create `cloudflare/worker/.dev.vars` with:

```dotenv
GROQ_API_KEY=your_local_test_key
```

`.dev.vars` must remain local and must never be committed. Do not paste the key
into source code, `wrangler.jsonc`, README files, or chat messages.

## Per-user rate limiting

The policy in this source is **10 AI requests per minute per Firebase UID**.

- If `AI_RATE_LIMITER` is configured, the Cloudflare binding is authoritative.
  It must return an object with a boolean `success` field. `success: false`
  means the user reached the limit and receives `429 RATE_LIMITED`.
- If the binding is configured but missing its `limit` function, throws, or
  returns a malformed result, the Worker fails closed with
  `503 AI_RATE_LIMITER_UNAVAILABLE`. It does not silently switch to a weaker
  counter.
- If the binding is not configured, local/in-isolate fallback counting is used.
  This counter is separate in each Worker isolate, so it is **not a globally
  authoritative production quota**. Multiple isolates can allow more than
  10 requests per minute for the same UID.
- The `ratelimits` example in `wrangler.jsonc` is intentionally commented out.
  The example namespace value is a placeholder. Do not enable it until the
  account's plan support and a real namespace ID are confirmed.

Do not describe the in-isolate fallback as a global per-user limit. Before
relying on a strict production quota, configure and verify an authoritative
Cloudflare rate limiter or another shared counter.

## Cron and R2 deployment settings

The confirmed production cron schedule is `*/5 * * * *`. It is present in
`wrangler.jsonc` under `triggers.crons` and runs `cleanupExpiredMedia()` every
five minutes.

The R2 binding in `wrangler.jsonc` is `MEDIA_BUCKET` -> `yokedin-media`.
Before deploying, compare both settings with the live Cloudflare Worker
configuration. A deployment can replace live Worker configuration, so do not
remove the cron trigger or R2 binding.

The configuration does not declare a custom domain or route. Keep the existing
`workers.dev` hostname unless a custom domain is separately confirmed.

## Local development and checks

Run these commands from `cloudflare/worker/`:

```bash
node --check src/index.js
npx wrangler dev
```

Use plain `wrangler dev` for local testing. Do not use `--remote` for these
tests: local R2 objects should be stored in Wrangler's local state rather than
accessing the production bucket.

Important local-testing boundaries:

- R2 operations use local Wrangler storage.
- Firebase token verification and Firestore membership reads still contact
  the real Firebase project over HTTPS.
- Use test accounts and test conversations. The Worker does not write to
  Firestore.
- Add a local `.dev.vars` file as shown above for successful Groq requests.
- Do not use `wrangler dev --remote` unless you intentionally want requests to
  run against live Cloudflare resources.

## Manual test checklist

Use a valid Firebase ID token and the appropriate request bodies.

1. `GET /health` -> `200`.
2. Upload an image using `POST /upload` -> `201`; then retrieve and delete the
   returned key using the expected media API headers.
3. For a key that does not exist in the local R2 bucket, `GET /media/<key>`
   -> `404`. To test ownership protection, upload as user A, then try to
   `GET` or `DELETE` as user B; the expected result is `403` where the route's
   ownership/membership checks apply.
4. Call an AI endpoint without a Firebase token -> `401`.
5. Call an AI endpoint with a valid token but a conversation the user does not
   belong to -> `403 FORBIDDEN`.
6. Call `/ai/summarize-chat` as a member with a valid body and local Groq key
   -> `200`.
7. Call `/ai/generate-meeting-minutes` and `/ai/smart-replies` as a member with
   valid bodies and local Groq key -> `200`.
8. Call an authorized AI endpoint without `GROQ_API_KEY` -> `503
   AI_NOT_CONFIGURED`.
9. With the local in-isolate fallback active, send 11 valid AI requests for
   the same UID within one minute. The first 10 reach the provider stage; the
   11th should return `429 RATE_LIMITED`. Restart the local Worker before this
   test so earlier requests have not already consumed the counter.
10. Test expired media by uploading an object with an expiry in the past in a
    controlled local test, then verify the GET response is `410`. Triggering
    scheduled cleanup can be tested separately; cleanup deletes expired
    objects from the local R2 state when running locally.
11. Upload media as user A, then attempt to delete that user's key using user
    B's token. Verify the expected ownership error response.

The rate-limit test requires a real member token and a real existing
conversation because authorization occurs before the limit is checked.
Successful AI tests also require a local Groq key. Tests that exercise
Firebase authorization require internet access to the Firebase project, even
when the Worker itself is running locally.

## Test coverage limitations

There is no automated Worker unit-test suite in this folder. The checklist
above is a manual smoke-test plan, not a claim that those tests have already
passed. The source has not been verified byte-for-byte against the currently
deployed dashboard Worker. Do not deploy until the local review and the live
Cloudflare configuration have both been checked.
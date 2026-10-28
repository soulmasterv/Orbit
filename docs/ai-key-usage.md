# Orbit AI Key Usage

Home → **AI Key Usage** displays read-only Classera 12F/12E Gemini accounting.
Uses the existing owner connection/token and Apple Charts; no extra navigation tab,
Gemini calls, notifications, key rotation or scheduled work.

## Verified source

- `/home/local/classera/shared/ai_usage.py` records attempts in `ai_requests`.
- Fields used: `day`, `timestamp`, `class_name`, `key_id`, `status`, `http_status`.
- `key_id` is the first 12 hex characters of SHA-256 of the key; hashes remain server-side.
- The shared `.env` defines four keys in configured order at inspection time. Classera
  12F/12E analyzers call the recorder. The database did **not** exist at inspection.
  No recorder/report was run to create it. Cached reports may not make an API request.
- Missing DB/table/recorded class data displays **Waiting for usage data**. A corrupt
  or incompatible schema returns a safe availability error, not a fabricated zero.

## Endpoint

`GET /api/classera/ai-key-usage?days=7&class_name=All`

Existing owner Bearer authentication; GET only; Cache-Control: no-store.
`days`: 1, 7, 30. `class_name`: All, 12F, 12E. Invalid/duplicate filters: 422;
unauthorized: 401; DB/configuration unavailable: 503. No raw errors returned.

Version 1 response contains state, timezone, selected filters, updated_at (Unix seconds),
configured_keys, active_keys_today, requests_today, rate_limits_today, chart_days,
daily [{day,key_id,label,requests}], keys [{id,label,configured,requests,successful,
failed,rate_limits,last_used}], recommendation, unmapped_keys.

Public IDs are generated `key-1`, `key-2`, etc.; labels `Key 1`, `Key 2`. No complete
API key, suffix, recorder hash, provider response, model or exception is serialized.
Configuration is parsed as data, never imported/executed. Shared order comes first;
explicit class-specific pools are read if present; duplicates count as one key.
Historical fingerprints missing from current configuration remain distinct `Unmapped
key N` rows. They do not inflate active **configured** key counts. Never guess an old
fingerprint's position or map it onto a newly configured secret.

Today counters always use the selected class and Cairo calendar day, matching the
recorder. Table counts use the selected period; last-used covers all recorded dates
for the class. Successful means recorder status `success`; all other attempts are
failed, including network errors; rate limits specifically mean HTTP 429.
Future dates and unrelated classes are excluded. Zero-use configured keys remain visible.
Chart: 7 calendar days for Today/7 Days, 30 for 30 Days, stacked daily counts by key.
No-use days remain in the chart domain. Partial current day is explicitly labeled.

Recommendations describe observed use. A different key used later on the same day
for the same class after a 429 is an ordering observation, not proof of automatic
failover, available quota, provider capacity or a need to buy/add keys.

## Read-only and refresh behavior

SQLite URI `mode=ro`, PRAGMA query_only, a consistent read transaction, one-second
busy timeout and two-second query execution budget. No schema/index/migration writes.
Open/manual/pull-to-refresh only; native requests coalesce and a generation protects
against stale filter responses. Existing valid snapshots survive transient failure.
Authentication/app-lock guards and the existing no-redirect URLSession remain in use.

## Deployment

Stage `ai_key_usage.py` and `install_ai_key_usage.py` in a private working directory
on Ubuntu. Run the installer without arguments to validate only. `--apply` backs up
the existing owner API and adds just the register call/module. Installer never restarts.
Only after explicit approval, restart `ios-server-control`; verify authorized GET 200,
unauthorized GET 401 and unchanged health/services. Other services need no restart.
The missing usage DB should remain absent after verification. Do not test using Gemini
or send reports/messages. Rollback: restore the backed-up `server_control.py`, then
obtain approval for the required API restart.

The native addition requires the new Orbit IPA. Build via the existing full GitHub
workflow; install through SideStore with the compatible bundle/Keychain identifiers.

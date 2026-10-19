# Ubuntu agent required before Services becomes live

## V4 contract preservation and future improvements

V4 adds no mandatory routes and does not change these response schemas. The client
consumes the existing endpoints when they are available; live availability cannot
be verified from this repository without the user's authenticated server access.
The checklist below documents the original V3.1 integration, not a new server rewrite.

Optional V4.x additions: a bounded authenticated event-history feed with safe IDs,
event type, actual result and timestamp; explicit container health metadata; PM2
uptime/restart count; Padel notification metadata and separate WhatsApp delivery/
billing state; per-integration last successful check. Preserve existing routes.
Do not infer delivered reports from a running scheduler or accepted POST. On-device
activity currently records only actions initiated on that iPhone.

No remote APNs, new ports, credentials, arbitrary actions or filesystem reads are
needed for the V4 UI. Docker logs may remain unavailable; the client explains this.

## BACKEND AGENT REQUIRED — V3.1 deployment checklist

No live service integration or log endpoint deployment has been performed. The app
does not substitute samples for missing live data. Inspect the actual Ubuntu source
and existing services; their private URLs, file paths and entrypoints are not available
in this repository and must be resolved on Ubuntu rather than guessed.

| Endpoint | Existing source to inspect and connect |
| --- | --- |
| GET `/api/services` Gemini fields | Existing authenticated Gemini monitor's health, 10 key status records, last authentication/generation checks. Server-to-server credentials stay in protected local configuration. |
| POST `/api/services/gemini/{key-1…key-10}/test` | Existing monitor's individual test operation with its current authentication, using a fixed safe ID to actual-key mapping on Ubuntu. No key supplied by iOS. |
| GET `/api/services` Classera fields | Existing Classera 1/2/3 scheduler/service and webhook state, last run and report metadata. Do not change scheduled automation. |
| POST `/api/services/classera/{classera-1…classera-3}/fire` | Each existing Classera automation's predefined report/fire entrypoint and intended WhatsApp recipients. Register callbacks only after inspecting those actual operations. |
| GET `/api/services` Padel fields | Existing Padel watcher, bot, dashboard and WhatsApp/webhook health. Read delivery/billing status from the existing WhatsApp/Meta response or delivery records separately from process health. |
| GET `/api/process/{id}/logs?limit=500` | Existing PM2 metadata `pm_id`, `pm_out_log_path`, `pm_err_log_path`. Select explicit approved process IDs/names on Ubuntu; register only their stdout/stderr files under approved log roots in LogsAdapter. |
| GET `/api/docker/{name}/logs?limit=500` | Existing approved Docker container names. Optional fixed callback using the existing local Docker integration, bounded tail and timeout, stdout/stderr separated. No new socket exposure. |
| Existing GET `/api/dashboard` optional process fields | PM2 `pm_uptime` converted into an uptime string and `restart_time` mapped to `restartCount`. Missing metadata is shown as Not reported. |

All routes use the EXISTING bearer check. POST bodies are empty; no client command,
recipient, file path, key or callback argument is accepted. Decode the Docker name
once as a single URL path segment before exact allowlist lookup. Reject extra query
parameters; logs accept only an integer `limit`, clamped to 1…500.

### Exact response contracts

`GET /api/services` returns:
```
{
  geminiHealth: string,
  gemini: [{id: string, name: string, status: string,
    lastAuthenticationCheck: ISO8601|null, lastGenerationCheck: ISO8601|null, canTest: boolean}],
  classera: [{id: string, name: string, status: string, schedulerStatus: string|null,
    webhookStatus: string|null, lastRun: ISO8601|null, lastReport: ISO8601|null, canFire: boolean}],
  padel: [{id: string, name: string, status: string, deliveryStatus: string|null,
    lastNotification: ISO8601|null}]
}
```
The arrays contain all 10 safe Gemini identifiers, Classera 1/2/3 and four Padel
components when the adapter is connected. Unknown data is Unknown, not fabricated
success. Public friendly names must be safe aliases. Gemini states include Working,
Rate Limited, Invalid, High Demand, Google Issue, Unknown. Padel application health
and WhatsApp Billing Required/Payment Ineligible/Delivery Failed remain separate.
Action success is `{ "ok": true }`; unknown action 404, missing provider 501,
authentication failure 401/403, duplicate action 409, upstream failure 502/503.

Both log endpoints return:
```
{ lines: [{id: string, stream: "stdout"|"stderr", text: string, timestamp: ISO8601|null}],
  truncated: boolean, fetchedAt: ISO8601 }
```
Read at most 64 KiB per approved PM2 stream, retain at most 500 total lines and 2000
characters per line. Do not read `.env`, environment variables or arbitrary paths.
The adapter redacts obvious Authorization/Bearer/API-key/token/password fields before
returning text. This is basic redaction, not a guarantee against every secret format;
inspect approved logs for additional service-specific sensitive data before exposing
them. Preserve per-stream order; use real timestamps to merge streams if available.
Do not invent timestamps. Docker callbacks need equivalent byte/line/time limits.

Deploy only after stub safety tests and auth/allowlist/redaction checks pass. Test live
status and logs read-only afterwards. Real WhatsApp fires require the human's explicit
confirmation and app device authentication; do not fire reports as deployment tests.

This repository did not contain the live backend. No Ubuntu access was available.
`services_adapter.py` is a reviewed integration component, not a drop-in replacement
or a claim that the live backend was inspected/deployed.

1. Inspect `/home/local/ios-swift-app/server_control.py` on Ubuntu and back it up.
   Compare its existing routes, auth and runtime against the app contract; preserve
   dashboard, PM2 and Docker behavior. Do not replace the working server wholesale.
2. Import one ServicesAdapter instance into that process. Route the three paths
   below AFTER the existing constant-time bearer-token authentication. Never pass
   `authenticated=True` based on client data. Use the existing HTTP response writer.
3. Inject a bounded/cached `reader()` returning the normalized dictionaries consumed
   by snapshot(). Inspect the real Gemini monitor API and existing authentication.
   Use its existing credentials server-to-server from protected local configuration.
   Map all 10 keys to key-1…key-10; no upstream raw JSON, names containing keys,
   credentials, exception text or environment variables may enter the public response.
4. Map Classera 1/2/3 scheduler, webhook, last-run and last-report timestamps. Register
   individual fire callbacks only after verifying the existing allowlisted operations
   and intended recipients. Do not modify the scheduled automation. Callbacks receive
   no client arguments. Report WhatsApp billing/payment problems separately from Padel
   watcher/bot/dashboard application health. Preserve Gemini monitor authentication.
5. Register Gemini tests individually after inspecting the actual monitor API. Keep
   network timeouts short and cache monitor reads to avoid slowing `/api/dashboard`.
   Prefer nonblocking job enqueue if a test/report is slow; report its last result on
   subsequent GETs. A command is never automatically retried by iOS.
6. Test unauthenticated requests, unknown IDs, secret redaction, backend errors and
   command deduplication using stubs. Do not fire real WhatsApp reports during tests.
   Deploy/restart only the existing API process using its normal method.
   Verify the public domain health and authenticated dashboard/Services afterwards.

## Routes

- GET `/api/services`: JSON schema in `Orbit/ServiceModels.swift`; timestamps
  are ISO 8601 strings. Missing provider returns 501 and the app shows a service-only
  availability message. Missing data reports Unknown rather than invented health.
- POST `/api/services/gemini/{key-1…key-10}/test`: bearer-authenticated predefined test.
- POST `/api/services/classera/{classera-1…classera-3}/fire`: bearer-authenticated
  predefined real WhatsApp report. The app asks explicit confirmation then device
  authentication immediately before the POST. LocalAuthentication is a local privacy
  gate, not server-verifiable authentication; server bearer auth remains mandatory.

Do not add a shell/SSH endpoint, Docker socket exposure, router forwarding, new public
ports, or put local configuration/credentials in GitHub. Adapter action cooldown is
30 seconds to suppress duplicate messages, independent of dashboard refresh.

## Signing and notifications

The pipeline creates an unsigned arm64 IPA for SideStore to re-sign. It does not
provision an Apple Developer push certificate, App ID push capability or APNs
entitlement. Remote APNs is therefore not implemented in this free-signing setup.
Only useful local notification testing remains visible; the event/preference types
remain available for a separately provisioned future transport. Do not add an
`aps-environment` entitlement without the required signing/provisioning change.

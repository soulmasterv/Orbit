> **Update (18 October 2026): Notifications retired.** Orbit no longer includes notification settings, permission prompts, local tests, APNs registration/delegates, Push Notifications capability or APNs entitlements. Existing local alerts are cleared on upgrade. After unlock the app attempts an authenticated DELETE for any saved legacy server device registration, retaining it for cleanup if the request fails. It never registers a new token. Legacy Keychain fields are retained solely to decode existing installations and perform revocation without losing drafts, pending sends or connection credentials.
>
> Feedback, recent events (when the app is open), manual messages and saved-operation recovery remain available. The APNs implementation/setup sections below describe the previous release and are historical, not features of the current app.

# Orbit / Students mobile API v1

Client additions only. The bot and server have not been changed or deployed by this work. Existing server-control bearer authentication, Students Keychain connection, moderation controls and app lock remain in place.

## Deployment gates and authentication

Authenticated `GET /api/mobile/capabilities` must decode as version 1. Message composition additionally requires `plain_text_messages` and `message_idempotency`. Events/push require the matching onboarding/feedback support flags. No assumption of deployment is made from an installed app update.

Every mobile, Students, feedback, event and push request uses only the configured Students HTTPS base URL and dedicated `X-API-Key`. Redirects are refused. No server-control bearer token is sent. Credentials and private local state are in device-only, when-unlocked Keychain records; private data is never logged.

## Routes

* `GET /api/events?limit=50`: newest-first fallback event feed, refreshed after launch/foreground unlock even without push permission.
* `GET /api/events/{UUID}`: authenticated event resolution after unlock. Fields: `id`, `kind`, `phone`, optional `feedback_id`, `created_at` Unix seconds. 404 means missing/deleted/expired. The app resolves onboarding against a fresh Students list and feedback against the complete feedback list.
* `GET /api/feedback?unresolved=false`: array of `{id:Int,phone:String,note:String,question:String,answer:String,ts:Int,resolved:Int}`. `resolved` is 0 or 1; timestamps use local display time. Newest-first, at most 100, no pagination. Notification targets outside that list are unavailable. No GET-by-ID endpoint is assumed.
* `PUT /api/feedback/{id}`: `{resolved:Bool}`; HTTP 200 `{ok:true}`. Resolve and reopen require device authorization. No mutation retry; a failed/uncertain action requires a successful refresh before another attempt.
* `PUT /api/push/devices/{installation_UUID}`: real hexadecimal APNs token, signed environment mapped to `sandbox` or `production`, supported topics, `enabled:true`. HTTP 200 `{ok:true,push:{...}}`. 409 is an environment conflict.
* `DELETE /api/push/devices/{installation_UUID}`: idempotent revocation with `{ok:true}`. Required for opt-out and before switching Students URL or key. The old destination remains saved until acknowledgment; failure prevents switching. Changing credentials is not a workaround for an unresolved saved send.
* `POST /api/students/{phone}/messages`: `{text:String}`, trimmed 1–3500 characters; `Idempotency-Key:UUID`. Active onboarding, explicit Allowed activity and an open window are rechecked immediately before dispatch; server checks remain authoritative.
* `GET /api/admin-messages/{UUID}`: recovery only. POST/GET result: `{request_id,phone,status,wa_id,error_code,created_at,updated_at,pricing}`. A deleted student's result may have an empty phone.

Send outcomes `pending`, `accepted`, `sent`, `delivered`, `read`, `failed`, `cancelled`, `unknown` are displayed distinctly. HTTP 200 does not imply delivery. Pricing is only optional Meta data (`billable`, `pricing_model`, `category`, `type`); empty means unknown. The app never labels window-open sends free.

The app persists the request UUID, destination and draft before the one POST. Duplicate taps and new sends while an operation exists are blocked. Timeouts, malformed responses, server failures and restarts keep that UUID. Active-screen recovery uses GET only with bounded delays 0/2/5/10 seconds, and again on next foreground. 404 is not permission to resend. Starting a new intentional operation requires explicit human review, including checking WhatsApp for pending/unknown outcomes. No automatic templates, reminders, AI requests or mutation retry are implemented. Server global limit is 30 newly reserved sends/minute.

401, 403, 404, 409, 422 and 429 have safe messages; no raw server response is shown. Existing inbound/pending-reply enforcement remains a backend responsibility and is not proven by this build.

## Apple signing and server setup

Repository target bundle ID: `com.servercontrol.app`; display name: Orbit. SideStore can rewrite the installed identifier. The real installed bundle, signed team and signed APNs environment are shown in **Students → Events, feedback & notifications**, only when readable from the executable's actual code-signature entitlement blob. An embedded provisioning profile or requested build setting is not used to guess them. Missing/unsupported entitlement encoding fails closed. APNs registration must also succeed on the real device before a token is uploaded.

The target declares Push Notifications and requests `aps-environment` (`development` for Debug, `production` for Release). This is a requested capability, not a provisioning profile. The GitHub build remains unsigned for sideloading. It cannot supply an actual Apple team, valid APNs entitlement, or proof of real delivery. Signing must grant the capability for the installed bundle ID; a free/rewritten SideStore profile may not support APNs. No Apple subscription, billing, certificate or account configuration is performed here.

The server operator needs the **actual signed** bundle identifier, team ID, matching APNs environment, key ID, a valid `.p8` signing key and a running worker. The `.p8` stays on Ubuntu with restrictive permissions. Never commit it, embed it in this app, paste it into chat or upload it as a GitHub secret for this unsigned workflow. `push.configured` only means settings/file presence, not valid credentials, a running worker, device delivery or notification display.

Push payloads must contain generic `aps` text plus only `event_id` and `kind`. No student name, phone, question, answer, note, token or API key belongs in a push. The app substitutes known generic content in foreground. Background lock-screen payload safety is the server's responsibility. Taps are deduplicated and resolved only after unlock. Pushes expire after one hour; events/reports and idempotency records have 30-day retention. Device registration does not backfill history.

Apple documentation: [Registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [APS environment entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment).

## Verification limits

Automated tests use mocked transports and fake credentials; no real WhatsApp message or push is sent. CI compiles the device app and runs the simulator test suite. A properly provisioned real iPhone test is still required for APNs permission/token/rotation and cold/warm notification delivery and taps. Backend deployment/enforcement, Meta delivery, Apple signing and UI behavior on an actual device must not be inferred from CI success.


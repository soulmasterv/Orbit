# Orbit JARVIS native app-session contract

Enabled after successful live Ubuntu verification on 2026-10-20. The app uses its existing authenticated Orbit session; User-Agent and installation UUID are never authenticators. No Cloudflare/JARVIS/bridge secrets are in the app or page JavaScript.

Native-only endpoints on https://control.admin-ai.site:
- POST /api/jarvis/app-session
- POST /api/jarvis/app-session/revoke

Both require the existing owner bearer, JSON version1, canonical lowercase installation_id UUID and a fresh22–128-character base64url nonce. No browser Origin/Cookie headers, redirects, failover or automatic mutation retries. Responses require JSON, no-store, at most64KiB; safe errors never expose upstream bodies.

Issuance echoes version/nonce and returns the exact https://jarvis.labbing.space/ entry_url, Unix expires_at with60–900 seconds remaining, and cookies. Exactly jarvis and CF_Authorization were observed live. Possible CF_Binding/CF_AppSession remain disabled until independently verified; arbitrary names and duplicates are rejected. All cookie records must be validated before any installation: exact non-dotted jarvis.labbing.space domain, path/, Secure/HttpOnly true, SameSite Strict, valid bounded RFC6265 cookie-octets, unexpired timestamps no later than the response expiry. Construction omits Domain to retain host-only scope and rechecks the parsed cookie. WebKit install/read-back is transactional with rollback on error, cancellation, lock or expiry.

Optional memory_available is a JSON boolean. Missing is treated as unavailable. The current server returns false because its existing /memory handler is absent. The authenticated probe remains in place: only200 confirms availability;404 explicitly marks the pre-existing capability gap; authentication failures and other unexpected statuses fail closed. Native Memory is disabled with an explanatory notice. School, phone, task, web authentication and stored data were preserved.

Every server issuance proves cookie-only HTML, JS/AudioWorklet, authenticated session JSON and voice WebSocket acceptance. Machine headers stay on Ubuntu and go only to the fixed JARVIS HTTPS origin. No permanent authorization headers are attached to native subresources. Strict service-token mode was off when verified and was not changed. Any later incompatibility fails closed rather than weakening Access.

Revoke echoes version/nonce/revoked:true and revokes only that installation's JARVIS session/socket. Native sign-out stops voice, invokes revoke once, and clears only JARVIS-scoped cookies; offline revocation is never claimed confirmed. Cloudflare's shared service JWT expires naturally; clearing locally is not per-device Cloudflare revocation. Background/lock/navigation cancel pending installation and clear local credentials. Expiry requires explicit Reconnect with a fresh nonce and never restarts the microphone.

Invalid successful responses trigger one compensating revoke with a new nonce, never reissuance. An uncertain transport failure is not replayed. The broker allows six authenticated operations/minute, private issuer twelve/minute, ten active devices and100 total JARVIS sessions; existing shared voice limits remain. Cookie expiry is checked against current time at each stage, so network proof latency does not falsely reject a fresh fifteen-minute private session. Independent read-only asset proofs run concurrently.

Deployment: existing current server plus private app-sessions.mjs issuer, loopback127.0.0.1:18082, and registered Flask broker. Active compose overlays retain phone/tasks plus compose.orbit.yaml. Only approved Service Auth policy6eb75a50-8a14-426f-8159-8f51a4a15b48 was attached to application39bf0d04-e0b8-4f14-90fb-e22e14711524, selecting replacement81ae922e-fbb7-4b0c-9f03-85de84e83b9f for15-minute sessions. Existing owner Allow policy remains. Replacement credential expires2026-10-21 at19:05UTC and stays in Ubuntu protected storage; the exposed old token is not reused.

Live Ubuntu tests passed for cookie-only assets/session/WebSocket handshake, owner/missing-bearer route protection and device-isolated revocation. No first-CSRF frame or audio was sent during handshake tests. Physical iPhone automatic-login, provider voice/audio, Stop, background, expiry and logout testing remains required. Simulator and synthetic tests must not be presented as physical-device proof.

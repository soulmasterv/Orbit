# Orbit native JARVIS handoff — deployment status

2026-10-20: The current Ubuntu JARVIS server has been extended with the private issuer, preserving its phone, task, school and web routes. Do not copy the older staged replacement server over it. The active compose overlays are compose.yaml, compose.phone.yaml, compose.tasks.yaml and the new compose.orbit.yaml. Issuer publication is loopback-only at 127.0.0.1:18082 with a private bridge secret mounted read-only. The Orbit broker routes are registered in the existing Flask API; existing bearer authentication is unchanged.

The replacement Cloudflare credential is stored only in the protected Ubuntu configuration (0600). It expires 2026-10-21 at 19:05 UTC. The exposed old credential is not reused. No secret file contents belong in this repository, logs, screenshots, or reports.

Service Auth policy preparation targets only exact application 39bf0d04-e0b8-4f14-90fb-e22e14711524, preserving its owner Allow policy. Only replacement record 81ae922e-fbb7-4b0c-9f03-85de84e83b9f is selected, with a 15-minute session. Application binding/strict protections are not relaxed. Policy saving and live cookie proof remain pending; native rollout stays disabled.

Explicit broker User-Agent headers address Cloudflare Browser Integrity Check compatibility, not authentication. The broker must still authenticate every native request with the existing owner bearer and every machine bootstrap with the protected replacement credential. Headers never identify an authorized owner on their own.

Native connection support installs validated cookies into persistent WebKit storage, reads them back before navigation, rolls back partial or stale installations, and rejects unexpected main-frame types/origins. It never forwards the Orbit bearer to JARVIS, never passes cookies through JavaScript and never starts the microphone. Background/lock/navigation stop voice, invalidate pending installs and clear scoped local cookies. Expiry requires explicit Reconnect; sign-out performs a single device revoke and reports uncertainty offline. Unrelated host cookies are preserved.

The current JARVIS source lacks its /memory endpoint, although it includes the frontend panel. This is an existing server capability gap. Do not silently remove the memory probe or restore an obsolete full server to hide it. Resolve or explicitly document this before declaring the full handoff verified.

Tests already performed on Ubuntu: 8 broker fixtures, 5 private issuer tests, and 9 existing authentication/audio/limiter tests, all passing. No live cookie-only proof, physical iPhone voice test, or native automatic login has yet been claimed.

Required release checks: exact public API routing with/without bearer, no Origin/redirect acceptance, replacement Service Auth, cookie-only HTML/JS/worklet/JSON/WebSocket acceptance, short cookie expiry, revoked-device isolation, normal browser Access plus password protection, CI full suite/IPA, and real iPhone login/voice/Stop/background/expiry/revocation. Keep rollout false if any required authentication check fails.

# Orbit JARVIS app-session client — staged, disabled

Status: server contract supplied; deployment and live cookie-only proof are **not confirmed**. The native JARVIS screen now uses the guarded broker factory, which fails closed before any request while rollout is false. `JarvisAppSessionRollout.enabled` is a source-level `false`; neither settings nor remote JSON can enable it. The optional-cookie allowlist is empty pending Ubuntu proof. The JARVIS screen now shows native connection status; its exact-origin microphone and lifecycle restrictions remain.

Native methods staged in `Orbit/JarvisAppSession.swift`:

- `POST https://control.admin-ai.site/api/jarvis/app-session`.
- `POST https://control.admin-ai.site/api/jarvis/app-session/revoke`.
- JSON `{version:1, installation_id:<canonical lowercase UUID>, nonce:<fresh 32-byte base64url random value>}`.
- Existing Orbit bearer supplied natively only; no browser Origin/Cookie headers, CORS, redirects, automatic retries or Tailscale failover. The broker owns a redirect-refusing ephemeral URLSession with native cookie storage disabled.
- Success must be HTTP 200, JSON, `Cache-Control: no-store`, and at most 64 KiB. Errors are mapped by HTTP status without using upstream response bodies.

Issuance validates version 1, exact nonce echo, exact `https://jarvis.labbing.space/` entry URL and expiry with 60–900 seconds remaining. Required cookie names are `jarvis` and `CF_Authorization`. Duplicate names and every optional name are rejected until the actual optional names have been independently confirmed and pinned in source; the only possible additions are `CF_Binding` and `CF_AppSession`.

All records must have the exact non-dotted domain `jarvis.labbing.space`, path `/`, Secure, HttpOnly, SameSite=Strict, a nonempty valid RFC 6265 cookie-octet value bounded to 8 KiB, and an unexpired timestamp no later than the response expiry. All records validate before any HTTPCookie objects are constructed. Set-Cookie parsing omits the Domain attribute to preserve host-only scope. The parsed objects are checked again for exact host scope, Strict policy, expiry and security flags, without reconstructing their properties. Tests use short-lived cookies relative to a frozen current clock to avoid platform lifetime caps on artificial far-future fixtures. The validated aggregate is redacted in string/debug descriptions. JarvisAppConnection provides transactional WebKit installation/read-back and rollback, but rollout remains disabled pending live proof.

An invalid successful response triggers one best-effort device-scoped revoke using a different fresh nonce. The broker records whether that compensating revocation was confirmed. This is not another issuance attempt. A failed or offline revoke is never represented as successful. Issuance and revoke requests cannot overlap in one broker. Lock, task cancellation and credential/connection changes prevent using a stale result. A transport failure never causes an automatic POST replay; an uncertain issuance may remain server-side until revoked or its short TTL expires.

Revocation requires HTTP 200 JSON `{version:1, nonce:<echo>, revoked:true}` and no-store. The backend must revoke only the specified installation's JARVIS session/socket. CF cookie revocation is local plus expiry; do not promise per-device revocation of the Cloudflare JWT.

## Required before enabling and connecting the UI

1. Fix the reported missing JARVIS modules and deploy the private issuer and Orbit broker safely. The reported fixture-only tests are not live proof.
2. Verify both exact public API paths reach the intended backend with real owner authentication; test unauthorized, invalid, rate-limit and unavailable cases. Never paste credentials or cookies into reports.
3. Run the Ubuntu verifier and report only pass/fail, actual cookie names/security attributes, expiry bounds, and tested HTML/JS/AudioWorklet/JSON/WebSocket paths. Do not return real cookie values to the app agent. Confirm success and error responses both have `Cache-Control: no-store`.
4. Confirm actual optional names, cookie-only acceptance, shared limits, per-device revoke isolation and unchanged public-web Access/password login protection. Complete any separately approved Cloudflare policy stage without weakening existing web protection.
5. Only after this evidence, pin the actual names and integrate issuance, transactional persistent WK cookie installation/read-back, rollback on lock/cancellation/failure, and explicit expiry/Reconnect/native Sign out. Use the existing persistent installation identity from Keychain. Keep cookie values out of JS, logs and the Orbit API origin. All installation/reconnect/revocation work must remain non-overlapping; validate again against current time before installation/navigation.
6. Native Sign out must Stop, revoke that installation and clear only the scoped cookies, showing uncertainty if offline. Expiry must Stop and clear expired credentials; an explicit Reconnect uses a fresh nonce and never starts voice automatically.
7. Run physical iPhone tests for automatic login, assets/worklet/authenticated WS, voice/replies, Stop/background/lock, Bluetooth/interruptions, expiry/reconnect and Memory create/edit/delete. Simulator/unit fixtures are not proof of these behaviors.

The staged client does not change Cloudflare policies, JARVIS login, CSRF, school knowledge, memory behavior, server origins, signing, or existing Orbit/Students features. No service-token secret, password, bearer credential or live cookie is in the repository.

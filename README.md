# Orbit V4 — Homelab Command Center

Native SwiftUI for iPhone (iOS 17+), built on Windows through the existing macOS
GitHub Actions pipeline. The unsigned arm64 IPA is intended for SideStore re-signing.

## V4

Home combines a compact server/resource summary, actual PM2/Docker counts, reported
integration health, two-column service tiles, local favorites and recent app actions.
Navigation is Home / PM2 / Docker / Activity / Settings. Gemini, Classera and Padel
remain directly accessible from Home, with compact service detail pages.

PM2 and Docker use compact manager rows with details, protected controls and log
navigation. The console has stdout/stderr, search/filter, copy line/visible text,
bounded history, refresh, live polling, independent follow/pause and jump to latest.
Unsupported log endpoints show an unavailable state. Common credential patterns
are redacted again on-device; backend redaction is still required.

One reusable icon/color/text status system distinguishes warnings, errors, stopped
states and unknown health. WhatsApp delivery/billing is separate from Padel process
health. Dates are human-readable. Loading preserves usable cached content and uses
subtle toolbar progress. Cancelled/suspended requests do not become false outages.

Favorites and the latest 100 locally initiated actions persist on this iPhone.
Activity records server acceptance or an uncertain outcome, not invented delivery
success. No tokens, response bodies, errors or log contents are persisted in activity.
There is no backend event-history endpoint currently consumed.

## Security and compatibility

App lock defaults to enabled and re-locks on background. Disabling it requires a
warning confirmation and device authentication. Commands always retain confirmation
and fresh LocalAuthentication, even with optional app lock disabled. Concurrent
commands are suppressed; POSTs never automatically retry or fail over. Tests never
fire real reports and need no real credentials or Ubuntu connection.

The bearer token remains in the original iOS Keychain identity. Settings supports
user-configured HTTPS servers, excluding URL credentials, queries and fragments.
Only the default production server automatically fails over to the known Tailscale
address for safe GETs; custom servers never send credentials to that fallback.
Redirects are rejected. Save only an address you trust to receive your bearer token.
No SSH/shell/file browser/Docker socket access or APNs entitlements are added.

Existing routes and JSON schemas remain unchanged. No new backend endpoint is
required by V4. Services and logs depend on the existing authenticated endpoints
actually being deployed; this repo does not provide access to the live Ubuntu host.
Missing uptime/restart/delivery fields are shown as not reported, not guessed.
See [backend/INTEGRATION.md](backend/INTEGRATION.md) for integration and future data.

## Build and review

Actions builds Release for arm64 iOS, runs backend safety and offline iOS tests,
validates version/icon/privacy/unsigned packaging, and uploads **Orbit-IPA**.
Successful runs also export **Orbit-Previews** with all major iPhone screens
in light/dark themes. Previews use test/DEBUG data only; production never substitutes
sample service/log data. Release bundle validation excludes the DEBUG preview entry.

Download the successful run's IPA artifact, extract its ZIP and import
`Orbit.ipa` into SideStore. Retain your Apple account and bundle identity
for in-place updates. Real-device biometric presentation and live integration health
still require verification on your iPhone.

# Allowed callers

Native entry: Students → Calls → Allowed Callers. Replaces legacy Diaa Friends editing; no native source calls `/api/jarvis-phone/diaa-friends`.

Uses existing native bearer-authenticated GET/POST `/api/jarvis/allowed-callers`. The proxy route in this repository mirrors the already deployed route; this update does not redeploy or restart the backend. No new credentials or WhatsApp session.

The list and details display enabled status, assigned incoming modes, admin default and caller-selected/current mode. The editor sends only the documented save fields; delete sends action and number. A selected mode is never included in the admin payload. The server preserves a selection while it remains assigned. Callers reset it with `/mode default`. No admin reset is presented.

Private JARVIS is not assignable to guests. The deployed API requires the existing owner to retain JARVIS and enabled=true and forbids owner deletion; native code identifies the protected owner by that mandatory mode, without embedding an owner phone number. The backend remains the final authority. Existing caller numbers are immutable in the editor because the API implements upsert, not atomic rename. Add the new caller, then remove the old caller to change a guest number.

One SIM/session and existing limits remain. Guest mode selection grants no owner command, mail, calendar or memory access. Existing Diaa playback and per-caller historical stats remain reachable. The call-history endpoint continues to use the existing Diaa tracking contract; no expanded tracking coverage is claimed.

Mutations require confirmation and existing device authorization. A failed/uncertain mutation retains the previous snapshot and requires a read refresh before another attempt, with no automatic resend. Views clear on lock/background/auth-context changes; brief Face ID inactivity preserves the editor. All native tests and layout captures use fixtures. Production validation is GET-only; no caller settings, messages or calls are changed for testing. Real incoming calls remain untested.

## Timed incoming override

The top card uses optional `override: {mode, expiresAt}` and `availableOverrideModes` from the same GET. Supported choices are restricted to server-listed Hossam, Bibo, Diaa and Noqta; private JARVIS is never offered. Presets 5/10/15/30 minutes and custom ASCII whole minutes 1–120. Start posts exactly `{action:"override",mode,minutes}`; Stop posts `{action:"clear_override"}`. Both require confirmation and existing device authorization and render the returned settings. No caller number, preference, client expiry or outgoing queue payload is sent.

TimelineView displays a countdown derived from Unix-millisecond server expiry. It never removes an override locally. At expiry it says “Checking server expiry…” until a GET returns null. Foreground/resume triggers a GET; while a server override exists, foreground-only reads run at most every five seconds, with a read scheduled near expiry. Expired-but-still-present or failed responses are bounded to five-second polling. Background tasks cancel, and sensitive snapshots clear. POST responses immediately update the snapshot. No automatic POST retry. Saved per-caller defaults/selections remain visible as temporarily overridden; a null override restores normal display.

The UI explains unknown incoming callers are included, caller /mode preferences do not bypass the active override, and stopping/expiry affects new calls without cutting off ongoing calls. Backend routing/expiry was deployed and tested separately; native tests use fixtures and do not exercise real incoming calls.

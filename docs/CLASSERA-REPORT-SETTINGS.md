# Classera report settings and verified invitations

The reviewed Report settings screen manages only Classera 1 (F)/12F and Classera
2 (E)/12E. The separate School database and current AI Key Usage UI are unchanged.
Native requests use the existing HTTPS Orbit URL and owner bearer from Keychain,
the no-redirect URLSession, app-lock guards and device-authorization preference.
Face ID off uses one explicit confirmation, not a biometric prompt.

## Report settings API v1

All routes require the existing owner Authorization bearer, reject browser Origin
and cross-site requests, and return Cache-Control: no-store. No provider credential
is exposed to the app. GET never migrates the database or sends a message.

- GET `/api/classera/report-settings/{classera-1|classera-2}`
- POST `.../bulk-ai/preview`, JSON `{"ai_enabled":0}` or 1; read-only preview.
- POST `.../bulk-ai/operations`, JSON request_id (canonical UUID),
  expected_revision (64 lowercase hex), ai_enabled (integer0/1),
  expected_affected_count (integer). One atomic SQLite transaction.
- PUT `.../next-notice`, JSON request_id, expected_revision, text (max1000chars).
  Empty text clears only an unclaimed queued notice. It sends nothing immediately.
- GET `.../operations/{request_id}` for recovery.
- POST `.../operations/{request_id}/cancel`, JSON `{}`; explicit confirmation only.
  If already completed, return its result. Otherwise atomically reserve a cancelled
  tombstone so a late original request cannot apply after recovery.

Settings contain version=1, class_id, class_name, revision, capabilities
`{bulk_ai,next_notice}`, notice_unavailable_reason, optional queued_notice and
latest_notice, and counts `{eligible,ai,no_ai,preserved}`. Preview adds ai_enabled
and affected_count. Mutation responses contain version, request_id, class_id,
kind, status (`completed` or `cancelled`), affected_count and full settings.
Notice details contain id,text,state,batch_id,created_at and optional outcome counts.

Errors:401unauthorized;403owner_not_permitted;404class/operation_not_found;
409review_latest_choices/preview_changed/request_id_conflict;422invalid_request;
503report_settings_unavailable or notice_contract_unverified. Responses never
include exception text, credentials or upstream bodies. Unknown transport/5xx
outcomes remain pending. There are no automatic mutation retries.

Only active, allowed, explicitly AI/No-AI subscriptions without a signup session
are eligible for bulk edits. Disabled/suspended/blocked/null-control/unknown-AI
rows, signup sessions, other classes, names and joined_at remain unchanged. Preview
revision includes relevant control/onboarding data so a concurrent signup or
suspension invalidates a stale write. Request IDs are idempotent and bound to the
exact class/action/body; another body cannot reuse an ID.

Native persists only pending request identity/scope in Keychain before submitting.
An uncertain outcome triggers one GET recovery, never another mutation. Unconfirmed
actions keep new changes disabled across reopening. Explicit cancellation handles
the case where a request never reached the API. Successful recovery reloads current
settings; generation guards reject older refreshes. Draft notice text stays in
memory and is cleared on lock/background/navigation away.

## Next-report notice delivery

User selected a separate WhatsApp notice: plaintext in a verified open24-hour
window, otherwise approved template `classera_wa_notice`, language `en_US`, with
one body parameter `{{1}}` containing the notice text. Example template body:
`Classera notice: {{1}}`. No dynamic media/header/buttons are assumed. The server
checks actual provider approval and parameter shape before the template route.
Until approved, closed/unknown-window notices are skipped and recorded. Plaintext
is never inferred from subscription/report/delivery status and requires at least
30seconds of verified remaining time. Eligibility is rechecked after window lookup.
A failed or uncertain plaintext send never falls back to another mutation.

The queue is bound to one logical class-wide report after generation/media upload
succeed. Both AI and No-AI recipients share the same frozen notice. Manual single
recipient sends and force resends never consume it. Batch records prevent a notice
queued later from being consumed by an already-started partial report. Each target
has an at-most-once reservation; timeouts/crashes are not automatically resent.
Only an accepted report is followed by its notice. Report failures, suspension,
closed/unknown windows and unavailable templates are recorded as notice outcomes;
they never break normal report delivery or roll a claimed notice into the next day.
An accepted notice means provider acceptance, not confirmed delivery/read.

The pure sender patch is AST checked: removing only the added hooks must recreate
the original producer AST exactly. It adds no imports/provider calls at module
import time, no report content/PDF changes and no scheduler/webhook configuration.
The producer integration receipt is valid only for the installed hashes of both
sender files. Without it native next_notice capability remains false.

## Class-ready invitation contract

Read-only Kapso verification on1Nov2026 confirmed exact `classera_class_ready`,
APPROVED, language `en_US`, one body parameter for class, a static text header,
and one Opt-in quick reply. Body: `Your class {{1}} is now supported. Reply below
to Opt-in.` The existing callback `selfservice_optin` starts onboarding; sending
an invitation never subscribes anyone or activates a scheduler. The verified
contract does not select the differently worded v3/v5 templates.

The new adapter requires a private verification receipt bound to the configured
phone ID and explicit per-class enable flags. It uses the existing private Kapso
key on Ubuntu, exact HTTPS origin, no redirects/retries and safe outcomes. Existing
class-wide preview/revision checks, atomic recipient reservations, eligibility
rechecks, operation history and receipt handling remain. Queued delivery events
are replayed when the provider message ID is bound to a recipient.

## Production deployment boundary

New code is a candidate until separately approved and installed. Required changes:
API modules, shared pure notice/transport modules, bounded hooks in the two actual
whatsapp_send.py files, two class-ready enable flags and private verification/
integration receipts. Back up and compare exact live hashes first. Only the Orbit
API needs restarting; report scripts load the helper on their next invocation.
No existing subscriber/preferences or queued notices are populated by installation.
Do not POST a real invitation, queue a real notice, force a report, change webhook
configuration, call Classera/Gemini, download a PDF, change signing or restart a
scheduler to test. Use fixtures and authenticated read-only capability checks.

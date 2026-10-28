# Delivery receipt updates and action authorization

## Observed issue
Raw Meta receipts already produced delivered/read records. Kapso outbound envelopes carried message.kapso.direction=outbound and status=sent|delivered|read|failed, but the existing webhook entered inbound processing and returned without recording those receipts. The legacy delivery table also allowed a delayed lower status to overwrite a later one.
The administrator turned off the Kapso event webhook and retained raw Meta. This update does not change that configuration.

## Backend repair
backend/orbit_delivery_receipts.py normalizes receipt-only outbound envelopes if encountered; no outbound envelope or test event can reach inbound bot handlers. Raw Meta and normal inbound handling are preserved.
A narrowly scoped installer patches only the webhook entry guard and update_by_message_id, with private source and SQLite backups. Monotonic status transitions prevent old Sent/Accepted from replacing Delivered/Read. A prior Failed state is not reopened by Sent; actual Delivered/Read can resolve it.
The monitoring event ledger follows the same rule.
The authenticated history GET supports an exact record_id SQL-bound filter, so the app can refresh one message without searching an arbitrary page.

A bounded local recovery reads at most8MiB of existing log text via ast.literal_eval, matches only already-recorded message IDs, and replays actual receipt statuses. It never executes text, calls inbound handlers, creates recipients, queries arbitrary URLs or sends/resends anything. A live replay matched14known messages; legacy totals were unchanged, and monitoring caught up with recorded evidence. Counts can subsequently change through normal traffic.

## App refresh
Classera history/statistics and delivery detail pages refresh with GET every15seconds only while active/visible. Detail state is mutable and replaces its original snapshot using exact record_id. Pull-to-refresh remains.
Classera saved plaintext operations also check status through GET while visible.
The School backend already had two Delivered admin-message records. It was left unchanged. Its open Message Status page now continues GET checks after Delivered so it can later display Read; mutation-recovery decisions remain separate.
Read receipts may remain unavailable if the provider never supplies them. Sent is never displayed as Delivered without evidence.

## Face ID off
The existing appLock.v4 setting now selects the action-authorization policy:
- enabled: existing LocalAuthentication / device passcode.
- disabled: confirmation only.
Explicitly confirmed flows carry a task-local confirmation marker, avoiding a second dialog. Actions without a prior confirmation (such as a class mode change) receive a native confirmation dialog. Cancel/backgrounding cancels the continuation and the existing access-generation checks prevent dispatch.
No owner API token, Students key, server authorization, messaging-window gate, recipient eligibility, mutation idempotency or rate limit is changed.

## Scope and verification
No detailed-report/Get Detailed View button changes: the user withdrew that request.
No School backend changes, no webhook configuration changes, no schedules or credentials changed, and no real WhatsApp send or resend.
Tests cover outbound/inbound/test separation, raw Meta body preservation, out-of-order updates, failed-state ordering, safe recorded-receipt replay, exact record lookup, read-only refresh, continuing after Delivered and confirmation-vs-device-auth policy.
Production read-only checks and physical iPhone checks must be reported separately from fixture tests.

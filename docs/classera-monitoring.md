# Classera waiting list, delivery history and daily statistics

## Current scope

Orbit has a Classera monitoring screen with Waiting List, Delivery History and Daily Statistics sections. Enter through Classera subscribers → Monitoring, through the Classera service page, or through a subscriber's Delivery history shortcut. It preserves the existing two student directories, full numbers in authorized native administrator views, app lock, signing, report controls and dark styling.

The class-ready sending integration was NOT verified to exist. The latest user instruction explicitly permits implementing the operation API but requires actual WhatsApp sending to remain disabled until the approved template contract is verified. Production registers **no sender adapter**, and the catalog reports template_verified=false. This cannot be enabled merely by changing a client flag, opening a preview, or marking a class available.

No real WhatsApp messages are needed or permitted during implementation tests. Do not enable FORCE_SEND or change templates, provider credentials, schedules or subscriptions.

## Authenticated API

All routes use Orbit's existing owner Bearer credential on the existing HTTPS Orbit API, never the school-assistant X-API-Key. Browser Origin/cross-site requests are rejected; responses use Cache-Control:no-store. Native authenticated requests refuse redirects. All responses have version:1.

- GET /api/classera/waiting-list
- GET /api/classera/class-ready/preview?class_id=12F
- POST /api/classera/class-ready/operations
- GET /api/classera/class-ready/operations/<request_id>
- GET /api/classera/delivery-history
- GET /api/classera/daily-statistics

class_id is the class code returned by the waiting-list API, for example 12F or 12D. Never derive eligibility from a label, directory name or historic report alone.

### Preview is read-only

GET /api/classera/class-ready/preview?class_id=12F returns:

    {
      "version": 1,
      "class_id": "12F",
      "class_name": "12F",
      "supported": true,
      "revision": "<64-character opaque hash>",
      "eligible_count": 2,
      "waiting_count": 3,
      "can_execute": false,
      "disabled_reason": "template_contract_unverified",
      "students": [
        {
          "phone": "<international digits>",
          "name": "<configured name>",
          "class_name": "12F",
          "joined_at": "<registration ISO timestamp>",
          "activity_status": "allowed",
          "signup": 0,
          "enrollment_key": "<opaque server enrollment hash>",
          "notification_status": "not_notified",
          "eligible": true
        }
      ],
      "updated_at": "<Unix seconds>"
    }

The above counts illustrate the response contract only; production figures come from SQL and are not hardcoded.

Eligible population: exact waiting_for_class enrollment, allowed activity, no signup in progress, class configuration supported, no persistent invitation reservation for that enrollment. can_execute additionally requires an installed verified sending adapter and verified template contract. The current production adapter is absent, so sending is disabled.

Class availability is read from instance configuration and provider-configuration presence. This is not a live provider health test and never activates a scheduler. CLASSERA_ENABLED=0 remains unsupported. Missing classes and unknown legacy classes fail closed.

### Execute is a separate explicit operation

POST /api/classera/class-ready/operations accepts exactly:

    {
      "request_id": "<canonical lowercase client UUID>",
      "class_id": "12F",
      "expected_revision": "<preview revision>",
      "expected_eligible_count": 2
    }

Confirmation names the class and eligible recipient count, followed by device authorization. A request identity is stored securely before the only POST. The backend independently recomputes the preview under a transaction, rejects changed revision/count and atomically reserves the whole eligible enrollment set.

Current production response:

    HTTP 503
    {"version":1,"error":"sending_disabled"}

This failure creates no recipient reservations and sends nothing. It records a disabled admin attempt in the audit table.

With a future explicitly verified adapter, a new valid reservation returns HTTP202:

    {
      "version":1,
      "request_id":"<UUID>",
      "class_id":"12F",
      "revision":"<preview revision>",
      "status":"reserved",
      "created_at":"<Unix seconds>",
      "updated_at":"<Unix seconds>",
      "total":2,
      "counts":{"reserved":2,"accepted":0,"sent":0,"delivered":0,"read":0,"failed":0,"unknown":0},
      "recipients":[{"phone":"<digits>","status":"reserved","error_code":null}]
    }

The single bounded worker rechecks enrollment, restrictions, availability and template verification before each dispatch. The sender must return accepted with a message_id, failed, or an uncertain outcome. Exceptions become unknown; no automatic retries occur. Accepted is not delivered.

Replaying the SAME UUID and SAME body is an idempotent read of the saved operation and returns HTTP200 without another dispatch. Reusing the UUID with another body is409. A new UUID cannot bypass the unique enrollment reservation. Failure and uncertainty do not release reservations for automatic resending.

No notification changes subscribers, signup state, AI preferences or schedulers. A later Subscribe now action must enter a separately verified student opt-in flow; a notification itself never activates an enrollment.

The app checks saved operation state with GET only. A404 after a timeout is not permission to resend. Completed operations require explicit review before the UI clears its local pending identity. Server-side reservations survive that local cleanup.

### Errors

- 401 unauthorized: owner credential missing or rejected.
- 403 owner_not_permitted: browser Origin or cross-site use.
- 404 class_not_found / operation_not_found.
- 409 preview_changed: membership, restrictions, count or revision changed.
- 409 request_id_conflict: same UUID, different body.
- 409 class_not_supported.
- 422 invalid_request: malformed body, UUID, count, revision or filters.
- 503 sending_disabled: no verified adapter/template contract; no invitation dispatched.
- 503 monitoring_unavailable: database/storage unavailable; do not infer an unsent outcome for a submitted operation.
- Native302/other redirects: refused; credentials are not forwarded.

No raw provider body, exception text, key or token is returned.

## History contract

GET /api/classera/delivery-history supports:
search, class_id, phone, template, status, report, from, to, sort=date|updated|class, direction=asc|desc, limit (1–100), offset.

The API performs SQL filtering, ordering and pagination using bound parameters and allowlisted sort columns. Date filtering means report date; records without a reliable report date are available in the unfiltered history but cannot be assigned to a guessed date.

Response fields:
version, records, total, offset, next_offset (nullable), updated_at, limitations.

Each record contains:
id, report, report_date (nullable), class_id, phone, student (nullable), template (nullable), message_id (nullable), status, created_at (nullable), updated_at, historical.

Current subscriber names are joined by phone AND class. Names are not invented for deleted or legacy profiles. Template and original attempt time remain unavailable when not recorded.

## Statistics contract and accounting

GET /api/classera/daily-statistics?from=YYYY-MM-DD&to=YYYY-MM-DD&class_id=12F
Dates are inclusive Cairo report dates, maximum366days. Native views select7or30days.

Response:
version, from, to, updated_at, reports, counts, attempts, expected, delivered_targets, not_attempted, skipped, delivery_rate, unknown_date_records, limitations.

Each report row includes:
id, date, class_id, report, counts, attempts, expected, delivered_targets, not_attempted, skipped, delivery_rate.

- counts: each attempt/message appears in exactly one latest-state category: reserved, accepted, sent, delivered, read, failed or unknown.
- attempts: recorded reservations/attempts, including legacy last-known entries. It is not a claim that every reserved request reached the provider.
- expected: unique recipient/report targets captured at normal sender entry. Forced one-person sends do not invent a whole-class expected denominator.
- delivered_targets: unique expected recipient/report targets with a confirmed delivered/read message. Multiple attempts for one target cannot inflate the rate.
- delivery_rate = delivered_targets / expected ×100; null when the complete denominator is unavailable or zero.
- not_attempted: expected targets without a recorded attempt or recorded skip.
- skipped: expected targets explicitly skipped before an attempt. Existing confirmed delivery entries are not counted as unsent skipped targets.
- null means unavailable, never zero or100%.
- overview totals and class rates remain unavailable when any included report lacks a reliable denominator.

The native app charts daily delivered/read message counts, latest-state breakdown and class rates. Unavailable rates are explained rather than drawn as zero. Class/date rows drill into filtered recipient history. No example counts are shown in production.

## Additive persistence

Original delivery_guard.deliveries records are preserved untouched by migration. New tables in the same delivery_state.db:
orbit_report_runs, orbit_report_targets, orbit_report_skips, orbit_delivery_attempts, orbit_delivery_events,
orbit_class_ready_operations, orbit_class_ready_recipients, orbit_class_ready_audit.

Legacy deliveries are imported once as last-known snapshots. Historical template names, original attempt timestamps, overwritten forced sends, missing events and expected-recipient lists cannot be reconstructed. Historical titles without a year do not receive a guessed report date.

Minimal hooks:
- report sender entry records expected targets for normal runs;
- final report/template/document provider dispatch records a separate attempt and actual template name;
- provider HTTP acceptance records the returned message ID, not delivery;
- the existing webhook forwards sent/delivered/read/failed plus its timestamp;
- unmatched early webhook events are retained and applied when the HTTP response later supplies that message ID;
- confirmed later delivery stages are not regressed by delayed earlier-stage events.

Observer failures do not turn a successful provider send into a resend. Existing delivery guard behavior, FORCE_SEND behavior, payloads, provider authentication and templates remain unchanged. Monitoring GETs never invoke a provider.

## Deployment and tests

backend/install_classera_monitoring.py stages five minimal source edits using current source hashes. Explicit apply backs up the original database through SQLite backup and the affected source files privately, creates additive tables, copies only the new modules and replaces verified source files atomically. It does not run a report or touch a scheduler configuration.

Required reloads: only ios-server-control and Classera-webhook, so the new route/observer imports are loaded. Existing report processes pick up hooks on their next normal launch. Do not fire a report to test installation.

Backend tests use temporary databases, fake senders and mocked provider responses. iOS tests verify owner-only headers, preview-only reads, canonical request bodies, authorization before POST, persistence before POST, no automatic POST retry, status-only recovery, safe errors, backward-compatible missing metadata, app-lock cleanup and stale-refresh rejection.

Physical iPhone layout, production template contract, Subscribe now callback and real delivery remain separate verification steps. Production sending must stay disabled until the exact approved template components and opt-in callback are verified and a reviewed server adapter is deliberately installed.

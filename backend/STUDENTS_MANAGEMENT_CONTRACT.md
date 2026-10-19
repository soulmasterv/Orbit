# Students management contract (app prepared; backend not deployed)

This document agrees the wire format expected by Orbit's Students feature. It
does not assert that the backend endpoints or bot enforcement currently exist.
Do not advertise management support until all enforcement described below works.

## Connection and authentication

All routes use the existing Students HTTPS base URL and `X-API-Key` credential
stored together in iOS Keychain. They never receive the Orbit API bearer
token. HTTP is rejected and redirects are not followed. No tunnel, API origin,
TLS exception, or existing connection setting is changed by this app update.

## Read and compatibility signal

`GET /api/students` keeps the existing newest-activity-first JSON array and all
existing fields. Each student adds `activity_status`, exactly one of:

* `allowed`: no activity restriction; onboarding and WhatsApp policy/window still apply.
* `suspended`: preserve the profile and pause bot replies indefinitely until resumed.
* `blocked`: preserve the profile and send no bot replies until unblocked.

Example addition: `"activity_status": "suspended"`.

The app treats missing, null, and unrecognized string values as **Unknown** and
disables management for that student. Unknown never implies allowed or consent.
Onboarding (`state`), reply activity, and the 24-hour messaging window are separate.
The app is not a sender and never uses an activity badge as authorization to send.

A recognized activity value is the compatibility signal for this contract.
The server must only include it after both mutation endpoints and inbound/queued
reply enforcement are deployed. If a future server needs independent capability
negotiation, that requires a separate contract change; it is not silently inferred.
404, 405, or 501 from a mutation disables controls for the current screen session.
Reopen Students after the backend upgrade and refresh to check compatibility again.

## Activity changes

`PUT /api/students/{phone}/activity`

Request JSON: `{"activity_status":"allowed"}`, `{"activity_status":"suspended"}`,
or `{"activity_status":"blocked"}`. No other fields are sent. `{phone}` is the
exact nonempty ASCII digit string returned by GET, including country code.

Suspend sends `suspended`; Block sends `blocked`; Resume and Unblock send `allowed`.
Unblock does not restore a previously suspended state: this three-state contract
explicitly requests Allowed. There is no scheduled expiry for suspension/blocking.

## Remove profile

`DELETE /api/students/{phone}` has **no body**. It removes the profile and any
activity restriction. A subsequent inbound message starts onboarding afresh.
It must also invalidate pending replies belonging to the removed profile, so
work created before deletion cannot send or recreate the old profile. Messages
already delivered to WhatsApp cannot be recalled by this action.

## Acknowledgement and failure semantics

Both mutations return **HTTP 200** and the valid JSON object `{"ok":true}` only
after the operation has committed, including its restriction/queue consequences.
The proposed notation `{"ok"}` is not valid JSON and is not accepted by the app.
Extra response fields may be ignored; raw response text is never shown in the UI.

Return 401 for an invalid/missing key, 403 for insufficient permission, 400/422
for invalid identifiers/status, 404 for a missing profile/route, and an appropriate
5xx response on failure. Never return a success acknowledgement for unsupported
or partially applied operations. Perform the same authentication on GET, PUT,
and DELETE; restrict these operations to the configured private administrator.

GET must be read-your-writes consistent: a GET started after acknowledgement
must show the committed status, or omit the removed student. Serialize state
changes and enforce restrictions atomically with bot work where necessary.
Activity PUTs should be idempotent; repeated DELETE must not recreate a profile.

## Required bot enforcement (backend implementation work)

* Check the persisted activity restriction on **every inbound event**, before
  onboarding/automatic responses, AI work, or any outbound reply is scheduled.
* Check again immediately before **every pending/queued/retried reply** is sent,
  including delayed jobs, retries, worker processes and concurrent instances.
* Block and suspend suppress all bot replies until explicitly returned to Allowed.
  Incoming messages must not reset either restriction or restart onboarding.
* Revoke queued work when a profile is removed; generation/version checks should
  prevent an old worker from replying to a newly onboarded profile with the same phone.
* Use persistence and transaction/locking rules appropriate to the deployment;
  restarting the bot must not clear restrictions. A request already handed off
  to an external messaging provider cannot be recalled; define this boundary.
* Resume/Unblock must not automatically flush old queued replies. Any new reply
  still requires current onboarding/consent and WhatsApp messaging eligibility.

## App safety and validation

All five controls require explicit confirmation and device authorization. Only
the current verified directory can supply a management target. Duplicate actions
are blocked; PUT/DELETE are never retried, failed over, or replayed on foregrounding.
Timeouts, cancellation after sending, malformed/negative acknowledgements and
unexpected responses are unconfirmed. The UI explains that the action may have
succeeded, then performs only a GET. If verification fails, controls stay disabled
until a successful refresh. The uncertain-result warning remains visible.

The app invalidates older in-flight refresh generations before a mutation. A late
old GET cannot overwrite its post-action snapshot. Countdown baselines and list
order are preserved during local removal. A successful DELETE returns to the list
even if subsequent verification fails; a server implementation must honor the
read-your-writes contract above to avoid reintroducing the deleted row.

Before declaring the controls operational, verify backend integration against
real inbound events, queued/delayed replies, worker restarts, concurrent sends,
all three activity states, and deletion/re-onboarding. App mocks and a successful
iOS build cannot prove server-side enforcement.

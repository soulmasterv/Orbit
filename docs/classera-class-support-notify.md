# Class support notifications: backend handoff

Status: not implemented or enabled. Orbit currently displays a disabled action for subscriptions with status `waiting_for_class`. There is no verified notification endpoint. Do not send messages during implementation or tests.

## Prompt for the Classera WhatsApp agent

Implement an authenticated admin action to notify ONE waiting Classera subscriber that their requested class is now supported, inviting them to opt in. This is not a reminder to finish signup, an automatic subscription, a daily report, or a broadcast.

Inspect `/home/local/classera-webhook/app.py`, `/home/local/classera/shared/subscribers.sqlite3`, and the existing owner-authenticated Orbit API at `/home/local/ios-swift-app/server_control.py`. Preserve the school assistant student database, existing Classera signup flow, report schedules, Kapso integration and credentials. Do not send any real WhatsApp messages during implementation or tests.

Use the existing Orbit owner authorization on `https://control.admin-ai.site` for native admin calls. Keep provider credentials on Ubuntu. Never forward the Orbit bearer token to WhatsApp or another origin. Do not introduce a public unauthenticated messaging route.

Required behavior:
- Target a single international-digits phone and its exact pending class. Check the latest database state and a real supported-class configuration on the server. `waiting_for_class` alone does not prove a class is supported.
- Allow only a currently supported class with a matching waiting record, and an allowed student. Blocked or suspended students must not be contacted. Never infer that legacy or unknown classes are supported.
- Require explicit admin confirmation in Orbit and device authorization before sending. The backend must still enforce all eligibility checks independently.
- Invite the student to opt in using the existing authenticated/validated WhatsApp button flow. Do not switch their subscription to active, enable AI, alter unrelated classes or overwrite an active signup session when sending the invitation. A student response must perform the opt-in.
- Respect the WhatsApp 24-hour window and existing Kapso/Meta rules. If an approved template is required and unavailable, report the action unavailable. Do not silently send free text outside the permitted window.
- Use a durable client request UUID and server-side idempotency. Persist the operation before dispatch and prevent duplicate invitations for the same pending enrollment. No automatic mutation retries or duplicate sends after a timeout.
- Provide an authenticated read-only operation-status lookup so Orbit can resolve an uncertain submission. Distinguish accepted/sent/delivered/failed/unknown; do not equate provider acceptance with delivery.
- Use revision/concurrency checks and revalidate before dispatch. Return safe errors for auth failure, unsupported class, missing/deleted enrollment, changed state, restriction, unavailable template and rate limit. Never return raw provider bodies, credentials or internal tracebacks.
- Add a verified capability/eligibility response with the pending class identifier, supported status, safe disabled reason, current revision and last invitation status. This lets Orbit enable Notify only after live compatibility is confirmed. Keep reads side-effect-free.
- Mock the provider and use a temporary database in tests. Cover unauthorized access, multi-class isolation, unsupported class, blocked/suspended students, opt-in not automatic, stale revision, signup races, expired/deleted enrollment, duplicate UUID, uncertain delivery, provider errors and no automatic send retries.

Return the exact proposed routes, request/response JSON, supported-class source, invitation/button handling and status lookup before the iOS action is enabled. Clearly separate implemented, deployed and live-verified behavior. No real-message verification without a separate explicit test-send approval.

## Separate school-assistant name editing

The school-assistant API currently exposes student reads, activity controls, deletion, subjects and messages, but no verified name-update endpoint. The Classera editor must not write to that database. For the school-bot agent: implement a narrowly scoped authenticated name update using its existing dedicated X-API-Key, server-side validation, concurrency checks and tests; return its exact contract before Orbit enables school-assistant name editing. Preserve onboarding state, grade, subjects, windows, activity restrictions and unrelated data. Do not send messages or complete onboarding merely by changing a name.

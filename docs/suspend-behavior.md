# Suspend-only administrator controls

Both student directories now expose Suspend and Resume, rather than separate Block and Suspend controls. Suspension is indefinite until explicitly resumed; it does not delete profiles, subscriptions or onboarding progress. Each database retains independent controls.

Existing backend `blocked` records are decoded and remain restricted. Orbit labels them Suspended, includes them in the Suspended filter, and permits an explicitly confirmed/device-authorized Resume using the existing `allowed` mutation. No automatic data migration or unlocking occurs. Legacy raw action/status identifiers remain compatible with existing API contracts.

## Verified deployed behavior

Read-only inspection and temporary-database/mocked-HTTP checks covered:
- Classera shared `can_reply`: rejects suspended/blocked records and fails closed on database errors.
- Classera webhook `post_whatsapp_payload` and `send_text`: check restrictions immediately before outbound provider calls.
- Both active Classera `classeraAI/whatsapp_send.py` `_post` functions: check restrictions for text, document and template/report sends, including recipients selected before a later suspension.
- Scheduled recipients: `subscribers.get_active_recipients` filters through the same restriction gate.
- School assistant `school_features.send_text` and `school_mobile.send_message`: validate activity/profile/revision at final dispatch using `can_deliver_on` and a SQLite write boundary.
- School assistant queued deliveries: changing the activity revision invalidates an older queued reply, even after Resume.

Important boundary: a message already in flight or accepted by Kapso/Meta cannot be recalled and may arrive after Suspend. Classera's existing gate is a pre-dispatch check, not an atomic cross-provider cancellation guarantee. No live send/recall test was performed. No server code, real students, schedules or provider settings were changed during this verification.

## Notification handoff received

The WhatsApp agent explicitly reports that eligibility, invitation dispatch/status and school-assistant name editing are NOT implemented, deployed or live-verified. Classera 12D remains disabled and must not be treated as supported merely because its directory exists. The invitation should say Subscribe now and enter explicit opt-in, without sending a daily report or auto-activating subscriptions.

The proposed `/api/classera/admin/class-ready/...` routes are not evidence of availability. Orbit's Notify control remains disabled. The earlier prompt in `docs/classera-class-support-notify.md` remains a backend handoff, not an implemented contract. Existing school-assistant Keychain credentials and networking remain unchanged.

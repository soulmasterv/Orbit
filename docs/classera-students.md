# Classera student directory

The school-assistant Students API and its dedicated X-API-Key settings are unchanged. Classera uses a separate directory backed directly by the existing shared subscriber database. There is no data migration or synchronization job; WhatsApp signups and Orbit read the same tables.

## Owner API

Use the existing Orbit HTTPS API base URL and the owner's existing runtime Bearer credential from Keychain. No credential is bundled in the app. These routes do not accept the separate Students X-API-Key. Browser Origin requests are rejected, redirects are not followed, responses are no-store, and mutations are never automatically retried.

- `GET /api/classera-students`: `{version:1,students:[...],classes:[{id,class_name}]}`.
- `GET /api/classera-students/{phone}`: `{phone,revision,subscriptions:[{phone,name,class_name,ai_enabled,status,joined_at,updated_at}],signup_session:null|{phone,step,name,class_name,updated_at}}`. An unknown phone returns an empty record and revision for creation.
- `PUT /api/classera-students/{phone}`: `{expected_revision,subscriptions:[{class_name,name,ai_enabled,status}]}`; returns the updated complete record. The list replaces only the editable 12F/12E subscriptions for that phone. An empty list removes these two subscriptions. Unknown classes are preserved. Phone uses 8–15 international digits without plus/spaces. Name is nonempty, at most 120 characters. AI is integer 0/1/null; waiting_for_class requires null. Status is active or waiting_for_class.

Classera 1 (F) maps to 12F; Classera 2 (E) maps to 12E. Existing joined_at values are preserved. A transaction locks the database before checking the revision and updating both classes. Concurrent changes, including an in-progress signup session, return 409. The signup session is never deleted or rewritten by this API. Finish that signup in WhatsApp before managing the student here.

401 means owner authentication failed, 403 browser use is denied, 409 requires a fresh read and review, 422 means invalid input, 503 means database unavailable. Missing databases fail closed instead of creating an empty database. Errors contain no private data or raw upstream output.

## Recipients and sending

Recipient GETs for the two supported instances now read active subscriptions from the same database used by the report sender. The old environment-file recipient PUT is rejected with an instruction to use the new directory; it no longer pretends to change delivery membership. Force-one continues to validate its chosen recipient against the current active class subscriptions. No report scripts, webhook onboarding logic, provider credentials or Kapso settings are changed. Saving subscriptions changes eligibility for future scheduled reports but does not send a WhatsApp message immediately.

## App

Students is the default screen, with separate School assistant and Classera subscribers entries. The tab bar is hidden in the student workspace; Workspace opens existing server controls. Backgrounding returns to Students. This is a presentation choice, not a second authorization boundary or a disguise for server controls. App lock remains the security control.

Classera shows two instances, not the legacy third card. Names, per-class AI preferences, status and explicit class removals are saved together after confirmation and device authorization. A failed/uncertain mutation triggers one GET and asks for review, never another mutation. Generation checks prevent stale replies from replacing current editor state. Real iPhone UI/device-auth checks remain required after installing the built IPA.

## Management controls

Student records include `activity_status` (allowed/suspended/blocked). Missing values decode as unknown and disable management. `PUT /api/classera-students/{phone}/activity` takes `{expected_revision,activity_status}` and returns the complete updated record. `DELETE /api/classera-students/{phone}` takes `{expected_revision}` and returns `{ok:true}`; it removes all Classera subscriptions, signup progress and the Classera restriction for that phone, not the other bot's profile. These mutations require the owner credential and device authorization. Revision conflicts return 409. The additive `orbit_student_controls` table in the same SQLite database preserves both original tables and their schemas.

The shared `classera_access.can_reply` gate is fail-closed if the database is unavailable. The webhook checks it before onboarding/AI handlers and again before outbound text/buttons. Both report senders check it immediately before their outgoing message calls; active-recipient enumeration also filters restrictions. Existing provider authentication, payloads, report generation and delivery guard remain unchanged. A message already accepted by the provider cannot be recalled by blocking.

The Classera details page offers a confirmed Force-send daily report action for each active class, using the existing single-recipient endpoint and its device authorization. Current recipient membership is fetched before requesting the action. No reports are sent automatically by opening/editing the directory. Classera intentionally has no subjects or free-text composer: it is the daily-report database. The school-assistant Students feature retains its original subjects, messaging and management controls.

## Deployment

Register `classera_students.register(app, SERVER_TOKEN)` in the existing authenticated Orbit API and configure `Directory` to the existing shared database path. Back up the live database and API before deployment. The API service's OS user must already have access to the database; do not loosen database permissions or expose SQLite. Use the existing HTTPS tunnel route. Run backend tests against temporary SQLite databases, then verify unauthenticated 401, owner GET 200 and recipient membership against the shared database without invoking send actions.

After the backup, install this additive table (do not recreate either existing table):

```sql
CREATE TABLE IF NOT EXISTS orbit_student_controls (
  phone TEXT PRIMARY KEY,
  activity_status TEXT NOT NULL CHECK(activity_status IN ('allowed','suspended','blocked')),
  updated_at TEXT NOT NULL
);
```

Install the shared gate module on the webhook/report Python import path. Check `can_reply` at inbound dispatch and immediately before every outbound message call, and filter active report recipients through it. Enable management only after these guards and the table are deployed together. Existing processes must reload the changed code. Backups and deployment scripts stay on the owner server; they do not contain credentials in this repository.

## Grouped Student Details and 24-hour window capability

Student Details uses the approved grouped design: Profile, Subscriptions (expand a class to edit), Messaging, Management. A bottom Save changes button is enabled only for changed subscription drafts. Names, class-specific preferences, subscription removals, revision conflicts, Face ID, one-person report confirmations, mutation retry protection, legacy preservation and the two separate databases retain their existing behavior. Waiting subscriptions display AI as Not set. Full phone numbers remain visible to the authenticated administrator.

The Classera database currently has no verified last-inbound timestamp or 24-hour messaging-window record. Signup updated_at, subscription timestamps and delivery/read receipts do NOT establish a window. The current production UI therefore displays Unavailable rather than a fabricated Closed/Open state. The school-assistant window is separate and unchanged.

The native model accepts this optional future read-only addition on the existing owner-authenticated Classera detail response:
```json
{
  "whatsapp_windows": [
    {"class_name":"12F","window_open":true,"seconds_left":5400,"last_inbound_at":1793010000},
    {"class_name":"12E","window_open":false,"seconds_left":0,"last_inbound_at":1792900000}
  ]
}
```
This is a capability contract, NOT a claim those fields are deployed. The WhatsApp backend must source it from verified student inbound events, scoped to the receiving WhatsApp business number mapped to each class. Never reuse the school-assistant database or another business number's window. Missing or inconsistent data must stay unavailable. seconds_left is a response-time snapshot (0–86400); last_inbound_at is Unix seconds and required for a known window. A closed response has zero seconds. The native countdown uses a monotonic clock locally; refreshing replaces its baseline. No per-second network polling or sending is introduced.

Window status is informational; it never enables reports, changes activity, or overrides backend/provider eligibility. Templated reports are separate from customer-service-window rules. Real provider/window verification and physical-device checks remain pending.

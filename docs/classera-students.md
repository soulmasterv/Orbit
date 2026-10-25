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

Classera shows two instances, not the legacy third card. Names, per-class AI preferences, status and explicit class removals are saved together after confirmation and device authorization. A failed/uncertain PUT triggers one GET and asks for review, never another PUT. Generation checks prevent stale replies from replacing current editor state. Real iPhone UI/device-auth checks remain required after installing the built IPA.

## Deployment

Register `classera_students.register(app, SERVER_TOKEN)` in the existing authenticated Orbit API and configure `Directory` to the existing shared database path. Back up the live database and API before deployment. The API service's OS user must already have access to the database; do not loosen database permissions or expose SQLite. Use the existing HTTPS tunnel route. Run backend tests against temporary SQLite databases, then verify unauthenticated 401, owner GET 200 and recipient membership against the shared database without invoking send actions.

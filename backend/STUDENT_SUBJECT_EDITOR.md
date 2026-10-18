# Student subject editor v1 — Orbit client

Uses the existing Students HTTPS URL and dedicated `X-API-Key` Keychain record. It never sends the server-control bearer token, changes schedules, or calls a WhatsApp send route.

## Availability verification

Opening **Students → Student Details → Edit optional subjects** first performs authenticated `GET /api/subjects/catalog`, validates `version == "subject-editor-v1"` and the full ten-ID catalog, then performs `GET /api/students/{phone}/subjects`. The catalog, matching phone/catalog version, 64-character opaque revision and current choices must all load successfully before editing/Save is enabled. Save also requires `editable:true`, actual changes, an unlocked app and no operation in progress. A read-only student remains visible with disabled checkboxes.

The development workspace cannot read the iPhone's Keychain credentials. Thus CI verifies these routes through mocked authenticated transports; it does not establish live endpoint deployment. The installed editor verifies the real deployment using the user's existing connection. No credentials should be pasted into chat or committed for verification.

## Selection and saving

Labels and order come from the catalog. Required displayed IDs are `english`, `arabic`, `religion`, permanently checked/locked. Quraan is not displayed in that required section. The 10 optional IDs are `advanced_math`, `statistics`, `chemistry`, `biology`, `physics`, `economics`, `accounting`, `computer_science_only`, `computer_studies`, `psychology`. Five `choice_pairs` arrays are validated as metadata; the client does not invent a one-choice-per-pair rule or assessment mappings. The server can reject invalid combinations with 422.

Checkboxes only change a local draft. One toolbar Save submits one `PUT /api/students/{phone}/subjects` after device authorization:

```json
{"optional_subjects":["chemistry","biology","computer_studies"],"expected_revision":"<latest 64-character opaque revision>","remove_legacy_subject_ids":[]}
```

An empty optional array is allowed and clears selectable electives. The response is the full current subject selection object; it replaces the saved choices and revision.

`computer_science` is the old combined ID, never a selectable new subject. New Computer Science is `computer_science_only`; Computer Studies is `computer_studies`. Nothing splits/remaps the old ID or copies an assessment schedule. Checking either/both new subjects never removes the old choice. Only a separate destructive confirmation marks the old choice for removal, and the following Save sends `remove_legacy_subject_ids:["computer_science"]`. The user can undo that mark before Save.

Unknown IDs and other legacy IDs are displayed read-only and remain server-owned. They are not passed as removal targets, reconstructed from labels, or silently dropped. The server contract automatically preserves them.

## Conflicts, failures and races

No mutation retries. A timeout, lost response, malformed result or uncertain server failure triggers a GET of current student subjects only. Matching current state is shown as verified; otherwise the draft is retained alongside the latest server choices and another Save is blocked pending explicit review. If recovery fails, Save stays disabled until successful verification. A 409 always requires reviewing the latest choices before saving again; the old revision is never replayed automatically.

401 is an authentication failure; 404 from the catalog means not deployed, while 404 on student routes means missing/removed student; 422 explains invalid choices and retains the draft. Raw response bodies and credentials are never shown. Save is serialized, older refresh generations cannot overwrite a newer save, and app lock/connection changes invalidate stale responses. Returning to a changed server requires reopening the editor.

Saving subjects does not send a WhatsApp message. Invalidating older WhatsApp subject-picker buttons is a backend responsibility specified by the contract, not an app-generated message or schedule operation. No live mutation or WhatsApp test is performed by CI.

# Classera class limit and student-owned opt-out

UI and production installation approved on 2 November 2026. Installed five files,
created the policy table and two triggers, and restarted only Classera-webhook and
ios-server-control. Local and public HTTPS owner GETs report enforcement; no-key
requests receive 401 and invalid override PUTs receive 422 without any valid mutation.
Existing subscriptions and overrides were not edited. School assistant data is unchanged.

Default is one distinct class per phone, counting active and paused subscriptions.
Opted-out and waiting-for-class rows do not occupy an active slot. Global suspension
does not release a slot. Existing multiple subscriptions are preserved and flagged;
they are never deleted, disabled or opted out automatically. An owner-only override
permits multiple classes for one phone. Removing the override preserves existing
rows and blocks additions until the student is within the limit.

GET directory/detail adds optional `subscription_policy`:
`{version:1,enforced:true,allow_multiple:false,max_classes:1,occupied_classes:1,
over_limit:false,counted_statuses:["active","paused"]}`.
With override, max_classes is null. Missing, invalid or unenforced metadata disables
the new add-class/override controls without hiding existing records.

PUT `/api/classera-students/{phone}/subscription-policy` uses the existing owner
Bearer credential, exact-origin redirect protections, native confirmation and
device-authorization pattern. Body: `expected_revision` and boolean `allow_multiple`.
Success returns the full refreshed student with revision and policy. 401/403 auth,
409 stale revision, 422 invalid body, 503 unactivated schema/unavailable. No automatic
retry; uncertain outcomes require a GET before another attempt. Policy changes are
included in the student revision. Dedicated School X-API-Key is never sent here.

SQLite triggers atomically enforce the limit for Orbit, WhatsApp signup and rejoin,
including concurrent writes. The private handlers catch only the exact limit error
and produce a truthful response, never a false signup success. All other errors
continue to their existing handling. Activation is explicit; normal API startup
only creates the additive policy table. The owner API maps the exact trigger error
to `409 {error:"subscription_limit_reached"}`. No provider is called for statistics
or policy operations.

Orbit exposes neither Opt out, Remove class nor Remove student for Classera. Native
payload validation rejects omitted existing classes and invented opted_out/paused/
disabled states. Existing states and AI preferences remain preserved. Owner DELETE
and omission-based removals are refused with 403 student_consent_required. Students
retain their WhatsApp opt-out path. Admins retain Suspend/Resume, forced AI choices,
and the override. Class preferences cannot lift administrator suspension.

Existing live HELP behavior was inspected, not message-tested: a suspended student
gets “Subscription status: Suspended. You cannot resume reports yourself. Contact
the administrator.” Reports and normal bot replies remain blocked. No unsolicited
suspension notification is introduced; that earlier request was withdrawn.

Prepared deployment covers five files (API directory module, policy module in API
and shared directories, narrow webhook signup catch, narrow management rejoin catch),
one override table and two triggers. Private code/database backups and expected-file
hash leases precede installation. Only Classera-webhook and ios-server-control
restart. Failure restores code and removes the new triggers without restoring an
old database over concurrent student changes. Reports, schedulers, credentials,
templates and webhooks configuration are unchanged. Installation/test sends zero
messages and changes no existing student preferences.

Backend fixtures: 158 passed after updated legacy tests. Preview checked at
320/390/736px. Native regression tests are prepared; Xcode compilation/full native
tests and IPA verification run in the normal workflow after the approved push.
Physical iPhone confirmation remains a device check.

# Prepared: opted-out profile removal and Gemini key metadata

UI and four-file production update approved. Installed with private backups and
restart of only ios-server-control. Local/public HTTPS auth checks passed; all12
monitor entries return redacted metadata, and invalid DELETE bodies are rejected
before any deletion. No valid profile removal or provider key test was performed.
Native build/IPA verification follows the approved push; School data remains unchanged.

Classera DELETE is eligible only when every stored subscription is exactly
opted_out, there is at least one subscription and no signup session. The owner API
rechecks under BEGIN IMMEDIATE with expected_revision. Mixed, active, paused,
waiting, unknown and empty records cannot be removed. Stale eligible revisions409;
ineligible403; auth401. Native UI only offers Remove student for the same predicate.
Confirmation/device authorization, no duplicate actions, no automatic DELETE retry.
Uncertain outcomes are resolved with GET; confirmed absence dismisses the detail.

Removal deletes the opted-out subscriptions, saved profile and per-phone override.
It preserves administrator restrictions, delivery history and audit data. Retained
restrictions alone do not recreate a ghost directory entry. Recreating a removed
profile preserves its suspension and restores the default one-class policy.
The other student database is untouched. No real profile is removed during tests.

Directory read snapshots carry a separate mutation revision. Successful management
and confirmed removal recovery invalidate the directory cache; an older in-flight
read cannot restore a removed row. This does not rotate auth context or trigger
reloads on brief background/foreground transitions.

Gemini Monitor keeps its stable generated Gemini N headings and health/test actions.
Optional metadata adds existing safe name/project labels, verified Classera pool
assignments, and recorded Classera usage in the last30 Cairo calendar days. Names
are matched by stable private monitor record ID, never by coincidental config order.
All secret comparisons/fingerprints stay on Ubuntu. Complete keys, fingerprints,
notes, raw monitor responses and unknown fields are never returned in metadata.

Configured and observed locations are separate. Coverage is Classera12F/12E only;
other uses are not inferred as absent. Missing DB/table means waiting, failed reads
mean unavailable, ready with no matching records means no Classera requests recorded.
No Gemini request, key test, rotation/config edit or monitor restart collects this.
Old/malformed optional metadata does not hide existing native health status.

Prepared production scope: four API-side files (classera_students.py,
orbit_runtime_readers.py, services_adapter.py, gemini_key_metadata.py), private code
backups and restart only ios-server-control. No schema, webhook, bot, schedule,
credential or provider changes. deploy-optout-tags.ps1 without Apply passed a
four-file source/hash/syntax check with writes0. Apply requires new approval.
Read-only metadata preview:12 labels available,4 monitored keys match Classera
configuration,1 has recorded Classera use in30days. No raw values exported.

Tests:169 backend fixtures passed with live network/subprocess/production DB blocked.
Five native tests cover deletion eligibility/auth/method/no retry/cache invalidation
and metadata compatibility/redaction, with a native key-label layout export. Run
Xcode/native/IPA checks in the normal workflow. Both mock previews checked320/390/736px;
only fake identities/labels. Physical iPhone verification remains a device-side check.

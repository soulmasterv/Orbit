# Orbit 4.1 — Compact, navigation and window status

Native-app changes only. The existing backend, proxies, bot state, provider integrations,
schedulers, signing, bundle identifiers, Keychain identities and workflow are unchanged.

## Approved Compact design

Blue accents, graphite surfaces, tighter shared panels, flat workspace links and compact
student rows. Existing functionality and five main tabs remain available. The last-observed
12F/12E report cards from the preceding update are preserved. Explicit light/system
appearance settings are still respected; the default is dark. JARVIS's existing server
web UI is preserved; native chrome uses the shared palette.

Version/build are read from the app bundle, visible in Home, Students, Settings and the
lock screen. The offline changelog is available in-app. Marketing version becomes 4.1.0;
the workflow continues supplying the actual release build number. Missing bundle metadata
is shown as unavailable rather than inventing a build number.

## Navigation and privacy

Previously ContentView reset the selected tab to Students and emptied Home's path on
backgrounding. AppRootView also removed ContentView when locked, destroying its state.

Presentation now has stable in-memory tab/stack ownership. Content remains mounted but
is opaque-covered, hidden from accessibility, disabled and excluded from hit testing
while locked. Existing authentication, five-minute expiry, request generation guards,
Keychain protection and device authorization remain in effect. Backgrounding still stops
requests and JARVIS audio. Pending confirmations and unsaved credential text are cleared.
Preserving a route never grants permission or replays an action.

Student details use phone-valued routes independent of a temporarily cleared directory.
Home and student lists/details retain meaningful scroll targets through refresh/lock.
No routes or student IDs are written to UserDefaults, logs or disk. Cold launch after
process termination uses the normal initial screen; this is not disk session restoration.
Unavailable or deleted data is shown as such; a remembered page does not recreate it.

## WhatsApp evidence and remaining backend limitation

Window states are independent of subscriptions, onboarding, AI preference, reply activity,
report sends and delivery/read receipts. Only explicit inbound-window response fields
are used. Open requires valid server seconds; false plus zero/missing seconds is closed;
missing/malformed/contradictory evidence is unknown. Expiry counts down monotonically.

The Classera client previously required last_inbound_at even for explicit closed status
or usable open+seconds_left, and suppressed window request errors with try?. It now has
separate loading/error/manual retry behavior. Optional timestamps no longer hide usable
window evidence. School missing window fields no longer fail the entire directory, and
unknown students are not included in the Closed filter. Cached data after a failed refresh
is not presented as current verified availability.

Repository inspection also found that classera_messaging.py returns null evidence after
a provider lookup failure. This update does not repair that server/provider failure or
pretend it means closed. Live Classera/Gemini/provider calls were prohibited during this
work, so no live payload or provider diagnosis is claimed. Backend/proxy investigation
or deployment requires separate approval. The existing send endpoint and its final
authorization/window check are unchanged; unknown evidence never enables sending.

## Regression coverage

New tests cover bundle metadata/changelog, open without optional inbound timestamp,
closed without optional timestamp, malformed/missing/contradictory data, monotonic
expiry, School unknown filtering, explicit retry/auth failure, concurrent read coalescing,
late response after lock, presentation identity through the privacy cover, deep-route/tab
retention on scene changes, and rendered window evidence. Existing window fixtures now
return the real messaging envelope rather than relying on a silently ignored decode error.

Run the existing full GitHub Actions workflow. Only mocked HTTP and fixture databases
are used by regression checks. Physical-device switching/Face ID, iOS process termination,
and actual provider window data remain separate verification steps. Do not install or
distribute an IPA as part of this task.

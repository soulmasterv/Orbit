# Orbit JARVIS Phone pilot

Prepared for backend activation; activation has not been performed by this integration.

Open Home → Phone controls. This entry is independent of JARVIS voice chat.
The pilot shows phone/ADB/Bluetooth/battery/health, delivery mode (web, WhatsApp,
SMS), Android acknowledgement, SMS forwarding and fixed automation controls.
Web mode means the existing web notification channel; it does not add native APNs.
Empty health reports and unavailable endpoints leave health/status unavailable.

The client reuses Orbit's bearer token, Keychain identity, HTTPS policy and
redirect-refusing session. No pairing key, alternative login or embedded secret.
Commands require confirmation, existing device authorization policy, canControl,
foreground access and a status less than 20 seconds old for the same connection
and access epoch. Lock, background, connection changes and attempted POSTs
invalidate freshness. Commands share Orbit's actionBusy guard and never retry or
fail over. A timeout is uncertain; refresh the actual state before another action.
Outgoing resume may place queued calls. SMS features may consume SIM credit.
Automation changes affect running services, not reboot configuration.

## Build and tests

The existing Build Orbit IPA workflow generates Orbit.xcodeproj from project.yml,
builds the Orbit scheme, runs offline iOS tests and backend/frontend checks, validates
the bundle and packages Orbit.ipa as Orbit-IPA. Source discovery already includes
the new Swift file; project names and persisted identifiers remain unchanged.
PhonePilotTests cover credential boundaries, empty health, unavailable/versioned
responses, stale status, authorization cancellation, lock during authorization,
single submission, timeouts without retries, and invalid commands.
The workflow also runs the 10 supplied backend pilot tests separately from the
existing backend suite. All backend tests use temporary databases and mocked
service commands. backend/phone_pilot is an inactive reference module, not imported
or registered by the existing backend. No deployment or restart runs from CI.

## Activation handoff

Use the original Orbit-phone-pilot README and deploy.py from the supplied folder
for the separately approved production change. Review the broker/API patch and
backups, register the two authenticated routes and restart only school-api and
ios-server-control. This checkout does not execute deploy.py.
Then update Android in place with the owner-signed v32 companion (do not uninstall),
grant SMS permissions as needed, and keep monitoring active. Settings remain
pending until Android acknowledges the saved revision.

After activation verify on-device: lock/unlock, background/foreground, stale or
changed connections, missing SMS permissions, pending/confirmed settings,
authorization cancellation and refused/uncertain commands. Any live resume that
could place queued calls requires deliberate operator action. No live calls or
messages are needed for the offline build/tests.

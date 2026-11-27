# Orbit phone notifications

Orbit Phone 0.6.0 exposes Settings → Notifications → Phone alerts → Delivery (Orbit or SMS),
with an independent **Use Orbit if SMS fails** switch. The Alerts tab caches the latest
40 history entries. SMS forwarding has separate preferences and delivery records.

## Backend integration

The owner-host phone alert broker is deployed separately from this repository. Apply
`patch_broker.py INPUT_BROKER OUTPUT_BROKER` to a reviewed copy. It rejects source drift.
Deploy the resulting broker alongside `phone_notifications.py` in its existing directory.
Back up the original source and SQLite database before replacement. Call the broker's
`init()` to create the additional tables, then restart its existing API, monitor and
delivery processes. Keep the same pairing key, database, endpoint, and authentication.
No backend credentials or owner-specific broker source belong in this repository.

The poll request adds `phone_delivery` (`web` means Orbit, or `sms`) and the boolean
`phone_fallback`. The authenticated response adds the same settings, `notification_history`,
and a `phone_alert` flag on SMS jobs. Older callers remain compatible. The new phone
preference controls incoming-call, phone-service, companion-connection and companion-health
events, including health-monitor failures. Legacy WhatsApp/call control settings do not
override it. The existing cooldown and debounce timers remain unchanged.

## Incident and delivery rules

- Choices are captured for a new incident. Errors and recoveries share its identifier.
- Recovery waits for an SMS sent/delivered receipt or push-service acceptance for its error.
  An orphan recovery and duplicate transitions are suppressed.
- Recovery follows the error's actual channel, including fallback. If recovery SMS fails
  with fallback enabled, the error is first posted to Orbit before recovery can follow it.
- Turning fallback off stops unsent automatic fallbacks, including pending incidents.
  Recovery for an error already sent through Orbit still stays on Orbit.
- SMS failure, unknown submission after 35 seconds, or an unavailable SIM/SMS permission
  can use Orbit only when the captured fallback choice and the current switch permit it.
  SMS accepted by Android is recorded as **submitted**, not confirmed delivered.
- A phone-offline event is never replayed later as an SMS from that phone. Without fallback,
  it remains unavailable. Samsung, SIM and SMS-permission outages cannot reliably notify
  through SMS. Orbit also depends on the Ubuntu API/delivery service being available.
- Direct APK error/recovery SMS paths are removed. The backend owns remote incident routing;
  the APK still records local connection transitions in its activity timeline.
- History stores category, incident, phase, chosen/actual channel, summary and delivery
  status. It retains the latest 200 events plus incident references required for correctness;
  the APK caches the latest 40. Settings exports exclude history, pairing credentials and
  forwarding contents. A push-service acceptance is not proof the user received a push.

## Validation

Run the existing backend tests and `test_phone_notifications.py` with unittest discovery.
To also run the real broker integration cases, set `ORBIT_PHONE_BROKER_SOURCE` to an
unmodified compatible broker copy, then run discovery. Integration tests patch it in
memory, use temporary databases, and mock push, SMS polling and gateway delivery. They
do not contact real recipients. Build the Android APK using `android-companion/build.ps1`
with the existing external signing directory. Do not disable Android install verification.

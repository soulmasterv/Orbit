# Workspace navigation and monitoring update

Home's Students shortcut now selects the existing Students tab, retaining its
navigation path and scroll memory. JARVIS, Downloads, Services and AI Key Usage
use typed destinations registered at the Home navigation root. Authentication,
app lock, microphone lifecycle and the five bottom tabs remain in place.

Delivery history can display explicit day/month/year dates in report titles
(including 12F 1/11/26). Title-derived dates are labelled. Yearless or invalid
dates stay unknown; stored dates take precedence. The optional backend adapter
change resolves title dates for filtering/statistics without backfilling SQLite.
Repository backend code is not a production deployment: live server filtering
and aggregation will not change until that adapter is separately approved and
installed. The native title-date display works with the existing response.

Missing historical expected-recipient snapshots remain unknown. The app explains
this once rather than displaying repeated unavailable metrics or using today's
subscriber count to invent a past denominator. Class-ready sending remains gated;
no template, sender, unsupported class or scheduler is enabled by these changes.

The current AI Key Usage UI and endpoint are unchanged at the user's request.

## Still outstanding

- Next-report-only notice consumption must be integrated with the verified class
  report batch and approved WhatsApp payload contract, not the first recipient.
- Selected-class bulk AI/No AI requires an atomic server transaction preserving
  disabled/suspended subscriptions and pending signups. Do not loop individual
  student mutations and claim atomic success.
- Verify the actual class-ready template and sender before enabling invitations.
- Live usage recorder/key-pool diagnostics require read-only Ubuntu access.
- Downloads native UI exists; its read-only backend installation has prior
  approval but has not been performed because server access is unavailable.

No production changes, restarts, real messages, provider requests, bot-state
changes or signing changes are part of this push. Tests use temporary fixtures.

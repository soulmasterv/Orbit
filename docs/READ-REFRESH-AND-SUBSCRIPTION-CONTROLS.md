# Brief resume, refresh and subscription controls

Automatic appearance/resume reads reuse a successful snapshot for up to sixty
monotonic-clock seconds in the same connection/unlock context. Explicit refresh
and mutation follow-up reads still fetch new data. Existing visible delivery and
School polling intervals remain unchanged; nothing polls while backgrounded.
Changes made elsewhere can therefore require a manual refresh or the next normal
refresh. This is a freshness trade-off, not an immediate live event subscription.

The app still denies API access and invalidates in-flight request epochs in the
background. Only an existing unlocked session opts into keeping recent read data.
The five-minute biometric lifetime is unchanged. A real lock, logout, changed
connection or changed credentials invalidates the cached context and verification.
A lock that expires while already backgrounded also invalidates it. No cache can
enable a background action or replace per-request server authorization.

Read snapshots and pending actions are separate. Confirmation sheets, actionable
previews and microphone/voice lifecycle behavior retain their safety cleanup.
Pending mutations keep their saved identity; recovery is read-only and never
automatically repeats a send or write. Revision validation remains server-side.

The Classera directory owns and coalesces its refresh task. Cancellation of a
SwiftUI pull-to-refresh waiter does not cancel or discard the owned read. Leaving
the screen or losing access can explicitly cancel it; generation/context checks
discard late responses. Real network failures keep the last successful directory
and a retryable error. Cancelled GETs retain their cancellation identity; cancelled
mutations retain an uncertain outcome and are not automatically retried.

The class subscription menu contains AI and No AI only. Adding a class requires an
explicit choice before saving; it never creates a disabled placeholder. Paused
means a student paused that class. Suspended is an administrator restriction, which
class preference changes cannot remove. Raw existing paused, opted_out and legacy
disabled records keep their status and AI preference when unrelated fields change.
Legacy disabled is shown as a restriction, with no new Disabled action offered.

Regression coverage includes cancellation/coalescing, stale responses, explicit
retry, one-minute expiry, credential boundaries, background access denial, hard
lock after temporary suspension, and separate administrator controls. Fixtures do
not send messages, call providers or change production subscriptions. This update
requires no production backend/proxy change or service restart.

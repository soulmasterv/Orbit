# Classera AI button activity

Activation requires an approved server installation. This audits the exact Get AI Analysis
WhatsApp button, distinct from AI subscription preference and reply delivery.

The existing owner-authenticated GET /api/classera/delivery-history adds
`ai_analysis: {status, requested_at}` to each record. No new public write endpoint.

States:

- requested: recorded real inbound button with exact outbound context and phone;
  requested_at is its validated Unix event timestamp.
- not_recorded: a new observed attempt after audit installation with no matching
  event. UI says “No click recorded”; it does not claim the student never pressed.
- unknown: missing audit installation, old imported records or missing attempt time.

No inference from AI preference, generated caches, provider usage or delivery/read
receipts. Exact outbound message identity prevents matching another class or report
retry. Early clicks can bind once the outbound message ID is recorded. Repeated
inbound IDs are idempotent; conflicting repeats do not reassign an existing event.

Record only real button branches in the already authenticated receive_webhook.
Do not instrument shared handle_ai_button: typed “AI” also calls that function.
Do not count View Detailed Report, typed text or other buttons as an AI-button press.
Missing context/identity/time cannot be guessed from the latest report.

Additive tables in the existing delivery_state.db store only inbound ID, parent
message ID, phone and event/receipt times, plus audit start time. No transcripts,
report contents, secrets, Gemini calls, messages or preference changes. GET is
read-only and does not create tables. Audit write failures cannot interrupt the bot.

Separate production approval is required for the audit files, a consistent
private backup, the additive migration, and restarting only Classera-webhook and
ios-server-control. The pure patch planner verifies that stripping the ten audit
lines restores the complete original webhook AST. Source hashes prevent overwriting
another agent's changes. Automated tests use isolated fixtures and do not send messages.

An existing opted-out subscription remains opted_out during another class edit.
The directory API accepts that status only when the current row already has it and
its AI value is unchanged. This is distinct from Disabled and unknown preferences.
The same preservation applies to paused; it displays Paused and retains its original
AI value, including null. Neither status is silently normalized to active or disabled.
The native list and details show an explicit Opted out label. Fully opted-out
students are hidden in All and shown by the Opted out filter; mixed active-class
subscriptions and unfinished onboarding remain visible. Suspended rows are stably
partitioned to the end of the same list without a new section.

Native history also shows original attempt time separately from last status update,
in the device timezone using a 12-hour clock. Missing historical times remain “Not
recorded.” The report date is never used as a fabricated send timestamp.

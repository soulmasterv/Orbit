# Orbit WhatsApp inbox

Native entry: Students → Calls → WhatsApp. School assistant is labeled AI; its API mode identifiers and credentials are unchanged. Fun calls uses the native owner API without a web-session handshake. Face ID remains required for calls.

The existing WhatsApp adapter and paired Baileys socket are reused. No second socket, account, pairing request or mobile secret is introduced. The adapter records direct text messages before the unchanged owner-command eligibility check. Outgoing manual messages use the socket's send method and are never submitted to the command gateway. The existing owner allowlist still gates all inbound commands. Existing web Controls authentication and CSRF checks remain unchanged.

The native bridge requires the existing Orbit bearer token and rejects browser Origin headers. Its upstream destination and paths are fixed to localhost. The existing server-held gateway key authenticates the private adapter endpoint. Source integration is recorded in whatsapp-inbox-integration.patch; copy whatsapp-inbox.mjs beside the adapter main file and register backend/orbit_jarvis_native.py with the existing Orbit API.

## API

- GET /api/jarvis/whatsapp: connected, chats (id, name, latest, at, unread).
- GET /api/jarvis/whatsapp/chats/{phone}?before={message_id}: connected, messages (last 50, older pages available).
- POST /api/jarvis/whatsapp/send: request_id (UUID), destination, text.
- GET /api/jarvis/whatsapp/requests/{UUID}: request_id, status, optional message_id.
- POST /api/jarvis/whatsapp/read: destination. Clears Orbit unread flags only.
- POST /api/jarvis/fun-call: existing fun_call payload. Uses the existing validated queueFun implementation and its existing deduplication rules.

Recipients accept local Egyptian and international numbers, including formatting. Groups, arbitrary JIDs and unresolved LID identities are excluded. Text is bounded to 12,000 UTF-16 units. Delivery/read states come from actual WhatsApp receipt updates and are not inferred from successful HTTP responses. Sent means socket acceptance; it does not mean delivered/read.

## Safety and retention

Inbox state lives in the existing adapter's /state/orbit-inbox.json volume, written atomically with mode 0600. Incoming message IDs and manual-send request IDs are durable across adapter restart. A send claim is persisted before transmission. Unknown/pending claims are never automatically resent, and the same request ID with different content is rejected. Restart converts unfinished claims to unknown. Orbit offers a read-only status check after an uncertain send and blocks subsequent sends in that composer.

The retained text window is bounded to 10,000 messages and 5 million UTF-16 units; chat previews list the latest 200 chats. Deduplication/send ledgers refuse new entries at 100,000 rather than evicting IDs and permitting replay. Protected native content is cleared on lock/background or authentication-context change; it is not persisted by Orbit. Backend storage is private to Ubuntu, not end-to-end encrypted at rest by this integration.

## Limits

No old-history resync is requested; messages appear from live events and history events the already-linked session happens to receive. No attachments, groups, editing, deletion, reactions or WhatsApp read-receipt sending. Orbit unread count is local to this inbox. Read receipts depend on WhatsApp availability and recipient privacy settings. This implementation is for native owner use; message text never authorizes third-party JARVIS commands.

Fixture tests cover authorization, Origin rejection, fixed routes, malformed input, recipient normalization, incoming deduplication, unread state, receipt progression, durable unknown-send protection, native uncertainty and lock cleanup. Verification sends no real WhatsApp messages or calls; physical-device and real-recipient acceptance tests remain separate.

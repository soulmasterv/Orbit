# Orbit WhatsApp inbox

Native entry: Students → Calls → WhatsApp. School assistant is labeled AI; its API mode identifiers and credentials are unchanged. Fun calls uses the native owner API without a web-session handshake. Face ID remains required for calls.

The existing WhatsApp adapter and paired Baileys socket are reused. No second socket, account, pairing request or mobile secret is introduced. The adapter records direct messages before the unchanged owner-command eligibility check. Outgoing manual messages use the socket's send method and are never submitted to the command gateway. The existing owner allowlist still gates all inbound commands. Existing web Controls authentication and CSRF checks remain unchanged.

The native bridge requires the existing Orbit bearer token and rejects browser Origin headers. Its upstream destination and paths are fixed to localhost. The existing server-held gateway key authenticates the private adapter endpoint. Source integration is recorded in whatsapp-inbox-integration.patch; copy whatsapp-inbox.mjs beside the adapter main file and register backend/orbit_jarvis_native.py with the existing Orbit API.

## API

- GET /api/jarvis/whatsapp: connected, chats (id, name, latest, at, unread).
- GET /api/jarvis/whatsapp/chats/{phone}?before={message_id}: connected, messages (last 50, older pages available).
- POST /api/jarvis/whatsapp/send: request_id (UUID), destination, text, optional media_id. Media captions are limited to 1,024 UTF-16 units.
- PUT /api/jarvis/whatsapp/media/{UUID}?kind=image|video|document&mime={MIME}: binary bytes up to 25 MB. Filename is base64 UTF-8 in X-Orbit-File-Name, optional bounded preview in X-Orbit-Thumbnail; filenames are kept out of the public request URL. An upload stores bytes only and never sends a message.
- GET /api/jarvis/whatsapp/media/{UUID}: authenticated binary attachment. It downloads/decrypts existing provider media only on demand, with a 60-second deadline and 25 MB limit.
- GET /api/jarvis/whatsapp/requests/{UUID}: request_id, status, optional message_id.
- POST /api/jarvis/whatsapp/read: destination. Clears Orbit unread flags only.
- POST /api/jarvis/fun-call: existing fun_call payload. Uses the existing validated queueFun implementation and its existing deduplication rules.

Recipients accept local Egyptian and international numbers, including formatting. Groups, arbitrary JIDs and unresolved LID identities are excluded. Text is bounded to 12,000 UTF-16 units. Delivery/read states come from actual WhatsApp receipt updates and are not inferred from successful HTTP responses. Sent means socket acceptance; it does not mean delivered/read. Message media is optional for compatibility with old text-only responses.

## Safety and retention

Inbox state lives in the existing adapter's /state/orbit-inbox.json volume, written atomically with mode 0600. Incoming message IDs and manual-send request IDs are durable across adapter restart. A send claim is persisted before transmission. Unknown/pending claims are never automatically resent, and the same request ID with different content is rejected. Restart converts unfinished claims to unknown. Orbit offers a read-only status check after an uncertain send and blocks subsequent sends in that composer.

The retained text window is bounded to 10,000 messages and 5 million UTF-16 units; chat previews list the latest 200 chats. Deduplication/send ledgers refuse new entries at 100,000 rather than evicting IDs and permitting replay. Protected native content is cleared on lock/background or authentication-context change; it is not persisted by Orbit. Backend storage is private to Ubuntu, not end-to-end encrypted at rest by this integration.

## Limits

No old-history resync is requested; messages appear from live events and history events the already-linked session happens to receive. Photos, videos and documents up to 25 MB are supported. Photos selected from the library are prepared as JPEG up to 2048 pixels; videos are prepared as 720p MP4. Files retain their original bytes. Native previews use Quick Look and protected app-owned temporary files. View-once media is excluded. No groups, voice notes, editing, deletion, reactions or WhatsApp read-receipt sending. Orbit unread count is local to this inbox. Read receipts depend on WhatsApp availability and recipient privacy settings. This implementation is for native owner use; message text never authorizes third-party JARVIS commands.

Media is stored outside any web root in the adapter's existing /state volume, under orbit-media, with mode 0700 directories and 0600 files. The blob cache is bounded to 500 MB and seven days; metadata is bounded to 20,000 attachments. Expired provider files may become unavailable. Media keys and provider download paths remain on Ubuntu. Public metadata contains only an opaque ID, kind, filename, MIME, optional size, availability and an optional small thumbnail. Download destinations are constrained to WhatsApp media hosts; arbitrary message-supplied server/internal URLs are rejected. Downloads are forced attachments with application/octet-stream, nosniff and no-store. User filenames never determine server filesystem paths.

The media install extends the text-only integration with whatsapp-media.mjs and whatsapp-media-integration.patch. Only the existing WhatsApp adapter and Orbit API need restarting. Pairing/configuration, the JARVIS command gateway and other phone services stay unchanged. Deployment state belongs in the operator receipt, not this source contract.

Fixture tests cover authorization, Origin rejection, fixed routes, malformed input, recipient normalization, incoming deduplication, unread state, receipt progression, durable unknown-send protection, native uncertainty and lock cleanup. Verification sends no real WhatsApp messages or calls; physical-device and real-recipient acceptance tests remain separate.

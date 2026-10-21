# Native JARVIS integration

Orbit uses its existing owner authentication to obtain a short-lived JARVIS app session. Browser login remains protected. Cloudflare credentials, JARVIS credentials and signing material stay on the server; they are never compiled into the app or sent to page JavaScript.

The app validates the complete response before installing cookies: protocol version, nonce echo, exact entry URL, bounded expiry, exact cookie allowlist, host-only scope, root path, Secure, HttpOnly and Strict SameSite. WebKit cookies are read back before navigation. Invalid or stale installation is rolled back. Microphone access still requires an explicit user gesture on trusted app content.

Backgrounding, app lock and navigation stop audio and invalidate pending work. Expiry offers explicit Reconnect. Sign-out requests device-scoped revocation and clears the relevant local cookies, reporting uncertainty when server revocation cannot be confirmed. Mutations are never automatically retried.

Independent read-only verification requests run concurrently to reduce bootstrap latency. The dedicated native handoff request has a 15-second request timeout and 20-second resource timeout; dashboard timeouts are unchanged.

Memory availability is an explicit capability. Missing capability is treated as unavailable, and the native shortcut stays disabled rather than assuming support. Deployment-specific observations and credentials belong in private operator records, not this repository.

Unit and simulator tests cover cookie validation, WebKit installation/read-back, rollback, duplicate suppression, stale replies, expiry, revocation and concurrency. Physical-device login, voice/audio, backgrounding and expiry testing remains a separate release check.

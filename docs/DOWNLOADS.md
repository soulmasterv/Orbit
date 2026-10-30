# Orbit Downloads — read-only files and daily-report previews

Authorized root: `/home/local/classera/downloads`. No writes, report generation,
Classera/provider calls, or WhatsApp sends. Files remain on Ubuntu; preview data
stays in app memory and is cleared on navigation away/background access revocation.
No iOS Files/iPhone Downloads access is involved.

## Deployment required — not installed or live-verified by this change

Copy backend/orbit_downloads.py beside the existing server_control.py. Inspect the
live Flask application and owner-token variable, then register exactly once:

```python
from orbit_downloads import register as register_downloads
register_downloads(app, EXISTING_OWNER_TOKEN_VARIABLE)
```

Use the existing token variable; do not create or expose another credential. The
root defaults to the exact user-confirmed path. No new host, port or proxy change
should be required if the existing owner API forwards /api/downloads paths.
Back up the live app first. Production changes and restarting only ios-server-control
require separate user approval. Do not restart Classera/webhook/schedulers.

After approved deployment, verify unauthorized requests return 401, authenticated
root/subfolder listing succeeds, and a user-selected existing PDF previews. Do not
print credentials, file contents or reports in diagnostics. Do not send messages.

## Contract

GET /api/downloads optionally takes `?folder=<id from a folder entry>`.
Owner Authorization bearer authentication, same native Orbit settings/Keychain.

```json
{"version":1,"truncated":false,"items":[{"id":"MTJG","name":"12F","kind":"folder","size":4096,"modified_at":1793000000}]}
```

GET /api/downloads/files/{id} returns file bytes. No externally supplied URL or
filesystem path is accepted. IDs encode relative paths; they are not credentials.
Every component is validated and opened relative to the root with NOFOLLOW.
Symlinks, hidden entries, traversal and special files are excluded. Only regular
files can be read. Listing is limited to 1,000 entries per folder (truncated=true
is explicit), folders first and newest entries first within each kind.

Responses are no-store; 401 authentication, 403 browser Origin/cross-site request,
404 missing file/folder, 413 over 25 MB, 422 invalid identifier/query, 503 unavailable
filesystem. Only GET routes exist. No raw upstream exceptions are returned.

Native downloads reject redirects through the existing NoRedirectDelegate, reuse
TLS validation, verify response origin/path, bound listing/file bytes, and check
authorization generation during/after streaming. No automatic retries/failover.
PDFKit renders PDF bytes; images and plain UTF-8 text are also previewed. Unsupported
formats are listed with a clear unavailable-preview state. HTML is never executed.

The app cannot show live files until the backend registration is deployed. It
shows an explicit unavailable state rather than fixtures. Test using mocks/temp
directories first; physical-iPhone PDF zoom/scroll and background cleanup still
need user device verification.

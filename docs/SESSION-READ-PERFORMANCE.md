# Read-only navigation performance

The primary performance issue addressed here is repeated cold reads: several
destinations owned snapshots in view-local state that was destroyed when the
destination was popped or when the selected student database changed.

Classera directory, key-usage filters and Home's report observations now share
memory-only session stores. The School directory store survives database switching
and list/detail visibility transfer. Downloads metadata and Classera monitoring
reads have bounded, filter/folder-specific caches; notification previews and
mutation authorization state are never cached or shared between destinations.

After authentication and the initial dashboard/services reads, the app preloads
only the Classera directory and default seven-day All usage summary concurrently.
Home renders without awaiting that preload. Repeated startup/resume tasks coalesce
and preload once per authentication context. A user-selected analytics filter is
not replaced by a late default preload. There is no report/PDF/voice preloading,
Gemini call, message submission or background execution added.

Automatic read freshness remains sixty seconds, using monotonic time. Fresh
snapshots reuse data immediately; expired snapshots remain visible while fetched
again. Manual refresh always reads, delivery monitoring still polls at fifteen
seconds while visible, School directory refresh/countdowns remain unchanged, and
mutation verification still uses direct API calls. Successful Classera edits retain
the existing directory-revision invalidation; notification attempts invalidate
monitoring read caches. Cached reads never authorize sends or substitute for a
fresh notification preview or WhatsApp-window validation.

Real app lock, owner sign-out and connection changes cancel reads and purge session
caches. Brief backgrounding retains read snapshots only under the existing valid
unlock session; network/actions stay prohibited while backgrounded. No browser
storage or disk persistence is added. Captured contexts/generations prevent old
reads from publishing into another authentication context or selected filter.

The appearance and navigation structure are unchanged. Regression tests cover
request counts, repeated preload, locked/missing credentials, brief resume, lock
and server-change invalidation, filter matching, manual refresh, bounded caches,
list/detail transfer, and a delayed filter response. Physical-device perceived
latency still requires checking the installed build; server/network delays cannot
be eliminated by native caching. No production API or service changes are needed.

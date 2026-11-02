# Classera usage attribution correction

On 2 November 2026, the recorder contained two successful requests for the Cairo
calendar day with `class_name="Unknown Class"`. The dashboard previously excluded
these entries even in the All filter. This was an accounting omission, not proof
that Gemini was unused.

The All filter now includes the shared Classera recorder's explicit `Unknown Class`
sentinel. Its requests contribute to today's totals, per-key counts and graph.
The existing recommendation explains how many requests lack a recorded class.
12F and 12E filters still include only their exact recorded class. Other unrelated
class labels remain excluded. Historical rows are never reassigned or changed.

The production report path also needed to forward its known class context:

```python
# classera-1/monitor.py
summary = analyze_report(dest, class_name="12F")
# classera-2/monitor.py
summary = analyze_report(dest, class_name="12E")

# shared/gemini_analyze.py: preserve existing locking/cache logic
def analyze_report(pdf_path, class_name=None):
    # Existing cache handling remains unchanged.
    summary = generate_summary(pdf_path, class_name=class_name)
    # Existing result/cache handling remains unchanged.
```

The snippets illustrate the changed call/signature, not replacement functions.
The actual edits changed two wrapper expressions and one call in each monitor.
No provider configuration, prompts, cache keys, schedules or message actions changed.
Existing callers remain compatible. Cache hits remain cache hits and do not create
fictitious API-request records. Already-running report children may retain old
imports; the next naturally started child loads the corrected forwarding. Each
scheduler invokes its monitor in a new Python process, so neither scheduler needed
a restart.

The separately approved four-file installation used exact-source guards, private
backups and atomic file replacement. Only `ios-server-control` was restarted.
Authenticated local and public HTTPS reads both verified two requests and one
active key for All; 12F and 12E remained zero for that day. Unauthenticated reads
were rejected with 401. Responses were no-store and checked privately against
configured secrets to ensure no full keys were exposed.

Validation: 170 guarded backend regression tests passed. The patched real wrapper
function was also extracted without importing producer modules and exercised with
a mocked provider, temporary fixture files, 12F/12E/default context and cache hits.
No real Gemini requests, report downloads, WhatsApp sends or database changes were
performed. No native UI code or IPA update is required for this correction.

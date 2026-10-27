"""Framework-independent, fail-closed adapter. Not a replacement for server_control.py.

Call handle only after the live server's EXISTING bearer check. Inject narrowly
scoped server-side readers/actions after inspecting the real upstream systems.
Never bind an extra port or expose the providers themselves to the client.
"""
from datetime import datetime
import re
from threading import Lock
from time import monotonic

def valid_key_id(value):
    return isinstance(value,str) and re.fullmatch(r"key-[1-9][0-9]{0,2}|key-1000",value) is not None
CLASSERA_IDS = ("classera-1", "classera-2", "classera-3")
PADEL_IDS = ("watcher", "bot", "dashboard", "whatsapp")
STATES = {"working", "rate limited", "invalid", "high demand", "google issue",
          "unknown", "online", "offline", "healthy", "unhealthy", "running", "stopped"}
DELIVERY = {"working", "unknown", "billing required", "payment ineligible",
            "delivery failed", "webhook unavailable"}

def state(value, allowed=STATES):
    return value.title() if isinstance(value, str) and value.lower() in allowed else "Unknown"

def timestamp(value):
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value
    except ValueError:
        return None

class ServicesAdapter:
    def __init__(self, reader=None, gemini_tests=None, classera_fires=None):
        self.reader = reader
        self.tests = {k: v for k, v in (gemini_tests or {}).items() if valid_key_id(k) and callable(v)}
        self.fires = {k: v for k, v in (classera_fires or {}).items() if k in CLASSERA_IDS and callable(v)}
        self.lock = Lock()
        self.busy = set()
        self.last_action = {}

    def handle(self, method, path, *, authenticated=False):
        if not authenticated:
            return 401, {"ok": False}
        if method == "GET" and path == "/api/services":
            if self.reader is None:
                return 501, {"ok": False}
            try:
                raw = self.reader()  # bounded/cached reads, never return raw downstream JSON
                return 200, self.snapshot(raw)
            except Exception:
                return 503, {"ok": False}  # never leak exception text or upstream credentials
        parts = path.split("/")
        if method != "POST" or len(parts) != 6 or parts[:3] != ["", "api", "services"]:
            return 404, {"ok": False}
        group, ident, action = parts[3:]
        callback = None
        if group == "gemini" and action == "test" and valid_key_id(ident):
            callback = self.tests.get(ident)
        elif group == "classera" and action == "fire" and ident in CLASSERA_IDS:
            callback = self.fires.get(ident)
        if callback is None:
            return 404, {"ok": False}
        key = (group, ident)
        with self.lock:
            if key in self.busy or monotonic() - self.last_action.get(key, -1000) < 30:
                return 409, {"ok": False}
            self.busy.add(key)
            self.last_action[key] = monotonic()
        try:
            callback()  # must be a predefined operation; no client arguments or shell strings
            return 200, {"ok": True}
        except Exception:
            return 502, {"ok": False}
        finally:
            with self.lock:
                self.busy.remove(key)

    def snapshot(self, raw):
        gemini = raw.get("gemini", {})
        classera = raw.get("classera", {})
        padel = raw.get("padel", {})
        result = {"geminiHealth": state(raw.get("geminiHealth")), "gemini": [], "classera": [], "padel": []}
        identities=sorted((k for k in gemini if valid_key_id(k)),key=lambda k:int(k.split("-")[1]))
        for ident in identities:
            item = gemini.get(ident, {})
            # Friendly names are generated locally, not copied from unsafe upstream fields.
            result["gemini"].append({"id": ident, "name": "Gemini " + ident.split("-")[-1],
                "status": state(item.get("status")), "lastAuthenticationCheck": timestamp(item.get("lastAuthenticationCheck")),
                "lastGenerationCheck": timestamp(item.get("lastGenerationCheck")), "canTest": ident in self.tests})
        for ident in CLASSERA_IDS:
            item = classera.get(ident, {})

            assessments = []
            for exam in item.get("upcomingAssessments", [])[:6]:
                if not isinstance(exam, dict):
                    continue

                assessments.append({
                    "date": str(exam.get("date") or "")[:10],
                    "label": str(exam.get("label") or "")[:120],
                    "type": str(exam.get("type") or "")[:30],
                    "week": exam.get("week")
                        if isinstance(exam.get("week"), int)
                        else None,
                    "subjects": [
                        str(subject)[:80]
                        for subject in exam.get("subjects", [])[:10]
                        if isinstance(subject, str)
                    ],
                })

            cache = item.get("aiCache", {})
            if not isinstance(cache, dict):
                cache = {}

            recent_cache = []
            for entry in cache.get("recent", [])[:5]:
                if not isinstance(entry, dict):
                    continue

                recent_cache.append({
                    "hash": str(entry.get("hash") or "")[:64],
                    "updatedAt": timestamp(entry.get("updatedAt")),
                    "hasSummary": bool(entry.get("hasSummary")),
                    "hasShortSummary": bool(entry.get("hasShortSummary")),
                    "hasExamMaterial": bool(entry.get("hasExamMaterial")),
                })

            result["classera"].append({
                "id": ident,
                "name": "Classera " + ident.split("-")[-1],
                "status": state(item.get("status")),
                "schedulerStatus": state(item.get("schedulerStatus")),
                "webhookStatus": state(item.get("webhookStatus")),
                "lastRun": timestamp(item.get("lastRun")),
                "nextRun": timestamp(item.get("nextRun")),
                "lastRunExitCode": item.get("lastRunExitCode")
                    if isinstance(item.get("lastRunExitCode"), int)
                    else None,
                "lastReport": timestamp(item.get("lastReport")),
                "lastReportName": str(item.get("lastReportName") or "")[:160] or None,
                "upcomingAssessments": assessments,
                "aiCache": {
                    "count": len(recent_cache),
                    "recent": recent_cache,
                },
                "whatsappStatus": str(
                    item.get("whatsappStatus") or "Unknown"
                )[:40],
                "sendingCount": int(item.get("sendingCount") or 0),
                "acceptedCount": int(item.get("acceptedCount") or 0),
                "sentCount": int(item.get("sentCount") or 0),
                "deliveredCount": int(item.get("deliveredCount") or 0),
                "readCount": int(item.get("readCount") or 0),
                "failedCount": int(item.get("failedCount") or 0),
                "unknownCount": int(item.get("unknownCount") or 0),
                "latestDeliveryAt": timestamp(
                    item.get("latestDeliveryAt")
                ),
                "latestDeliveryReport": str(
                    item.get("latestDeliveryReport") or ""
                )[:160] or None,
                "recipients": [
                    str(x)
                    for x in (item.get("recipients") or [])
                    if str(x).strip()
                ],
                "canEditRecipients": bool(
                    item.get("canEditRecipients")
                ),
                "canForceOne": bool(
                    item.get("canForceOne")
                ),
                "canFire": ident in self.fires,
                "canForceFire": bool(item.get("canForceFire")),
            })
        for ident in PADEL_IDS:
            item = padel.get(ident, {})
            result["padel"].append({"id": ident, "name": "Padel " + ident.title(),
                "status": state(item.get("status")), "deliveryStatus": state(item.get("deliveryStatus"), DELIVERY),
                "lastNotification": timestamp(item.get("lastNotification"))})
        return result

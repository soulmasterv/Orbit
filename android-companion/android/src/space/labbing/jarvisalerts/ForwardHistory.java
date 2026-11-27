package space.labbing.jarvisalerts;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;

/** Stores delivery metadata only. Message text and sender addresses stay out of history. */
final class ForwardHistory {
    static void record(Context context, String id, String status, int parts, int error) {
        synchronized (AlertService.LOCK) {
            JSONArray old;
            try {
                old = new JSONArray(AlertService.prefs(context).getString("forwardHistory", "[]"));
            } catch (Exception ignored) {
                old = new JSONArray();
            }
            JSONArray next = new JSONArray();
            JSONObject entry = null;
            for (int index = 0; index < old.length(); index++) {
                JSONObject item = old.optJSONObject(index);
                if (item != null && id.equals(item.optString("id"))) entry = item;
            }
            try {
                if (entry == null) {
                    entry = new JSONObject();
                    entry.put("id", id);
                    entry.put("at", System.currentTimeMillis());
                }
                String previous = entry.optString("status");
                boolean downgrade = "delivered".equals(previous)
                    || ("failed".equals(previous) && !"delivered".equals(status))
                    || ("submitted".equals(previous) && "sending".equals(status));
                if (!downgrade) {
                    entry.put("status", status);
                    entry.put("parts", parts);
                    entry.put("error", error);
                    entry.put("updated", System.currentTimeMillis());
                }
                next.put(entry);
                for (int index = 0; index < old.length() && next.length() < 20; index++) {
                    JSONObject item = old.optJSONObject(index);
                    if (item != null && !id.equals(item.optString("id"))) next.put(item);
                }
                AlertService.prefs(context).edit().putString("forwardHistory", next.toString()).commit();
                ActivityTimeline.record(context, "Forward result · " + label(entry.optString("status")));
                PhoneWidget.updateAll(context);
            } catch (Exception ignored) { }
        }
    }

    static String label(String status) {
        switch (status) {
            case "delivered": return "Delivery confirmed";
            case "submitted": return "Sent · delivery unconfirmed";
            case "failed": return "Sending failed";
            case "sending": return "Waiting for carrier result";
            case "cancelled": return "Cancelled before sending";
            default: return "Result unavailable";
        }
    }
}

package space.labbing.jarvisalerts;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONArray;
import org.json.JSONObject;

final class ActivityTimeline {
    static void record(Context context, String event) {
        synchronized (AlertService.LOCK) {
            try {
                SharedPreferences prefs = AlertService.prefs(context);
                JSONArray old = new JSONArray(prefs.getString("activityTimeline", "[]"));
                JSONObject first = old.optJSONObject(0);
                if (first != null && event.equals(first.optString("event"))) return;
                JSONArray next = new JSONArray();
                next.put(new JSONObject().put("event", event).put("at", System.currentTimeMillis()));
                for (int index = 0; index < old.length() && index < 99; index++) next.put(old.get(index));
                prefs.edit().putString("activityTimeline", next.toString()).commit();
            } catch (Exception ignored) { }
        }
    }

    static void observe(Context context) {
        SharedPreferences prefs = AlertService.prefs(context);
        boolean sms = context.checkSelfPermission(android.Manifest.permission.SEND_SMS) == 0
            && context.checkSelfPermission(android.Manifest.permission.RECEIVE_SMS) == 0;
        String state = "Monitoring " + (prefs.getBoolean("enabled", false) ? "on" : "off")
            + " · forwarding " + (prefs.getBoolean("forwardEnabled", false) ? "on" : "off")
            + " · " + prefs.getString("notificationMode", "web") + " alerts"
            + " · SMS permissions " + (sms ? "granted" : "missing");
        if (!state.equals(prefs.getString("lastObservedSettings", ""))) {
            prefs.edit().putString("lastObservedSettings", state).commit();
            record(context, state);
        }
    }
}

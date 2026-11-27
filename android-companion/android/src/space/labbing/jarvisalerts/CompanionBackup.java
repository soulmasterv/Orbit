package space.labbing.jarvisalerts;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import java.io.*;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

final class CompanionBackup {
    static String export(Context context) throws Exception {
        SharedPreferences prefs = AlertService.prefs(context);
        return new JSONObject().put("format", "orbit-phone-settings").put("version", 1)
            .put("channel", prefs.getString("notificationMode", "web"))
            .put("phone_delivery",prefs.getString("phoneAlertDelivery","web"))
            .put("phone_fallback",prefs.getBoolean("phoneAlertFallback",true))
            .put("daily_parts", prefs.getInt("forwardDailyLimit", 0))
            .put("part_price_mils", prefs.getLong("forwardPartPriceMils", 0))
            .put("block_roaming", prefs.getBoolean("forwardBlockRoaming", false)).toString(2);
    }
    static JSONObject read(Context context, Uri uri) throws Exception {
        try (InputStream in = context.getContentResolver().openInputStream(uri)) {
            if (in == null) throw new IOException();
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[1024];
            int count;
            while ((count = in.read(buffer)) != -1) {
                bytes.write(buffer, 0, count);
                if (bytes.size() > 8192) throw new IOException("Too large");
            }
            JSONObject value = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
            validate(value);
            return value;
        }
    }
    private static void validate(JSONObject value) throws Exception {
        if (!"orbit-phone-settings".equals(value.getString("format")) || value.getInt("version") != 1) throw new IOException();
        String channel = value.getString("channel");
        if (!channel.equals("web") && !channel.equals("whatsapp") && !channel.equals("sms")) throw new IOException();
        String phone=value.optString("phone_delivery","web");
        if(!phone.equals("web")&&!phone.equals("sms"))throw new IOException();
        if(value.has("phone_fallback")&&!(value.get("phone_fallback") instanceof Boolean))throw new IOException();
        int limit = value.getInt("daily_parts");
        long price = value.getLong("part_price_mils");
        if (limit < 0 || limit > 10000 || price < 0 || price > 100000000 || !(value.get("block_roaming") instanceof Boolean)) throw new IOException();
    }
    static void restore(Context context, JSONObject value) throws Exception {
        validate(value);
        synchronized (AlertService.LOCK) {
        if (("sms".equals(value.getString("channel")) || "sms".equals(value.optString("phone_delivery","web"))) && context.checkSelfPermission(android.Manifest.permission.SEND_SMS) != 0)
            throw new IOException("SMS permission required");
        if (!AlertService.prefs(context).edit().putString("notificationMode", value.getString("channel"))
            .putInt("forwardDailyLimit", value.getInt("daily_parts"))
            .putLong("forwardPartPriceMils", value.getLong("part_price_mils"))
            .putBoolean("forwardBlockRoaming", value.getBoolean("block_roaming"))
            .putString("phoneAlertDelivery",value.optString("phone_delivery","web"))
            .putBoolean("phoneAlertFallback",value.optBoolean("phone_fallback",true))
            .putBoolean("phoneAlertSynced",false).putBoolean("channelSynced", false).commit()) throw new IOException();
        ActivityTimeline.record(context, "Settings restored from backup");
        }
    }
    static void write(Context context, Uri uri) throws Exception {
        try (OutputStream out = context.getContentResolver().openOutputStream(uri, "wt")) {
            if (out == null) throw new IOException();
            out.write(export(context).getBytes(StandardCharsets.UTF_8));
        }
    }
}

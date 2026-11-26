package space.labbing.jarvisalerts;

import android.Manifest;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.telephony.SmsManager;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import java.text.SimpleDateFormat;
import java.util.*;

final class ForwardControls {
    static String day(long now) { return new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(new Date(now)); }
    static int used(Context context) {
        SharedPreferences prefs = AlertService.prefs(context);
        return day(System.currentTimeMillis()).equals(prefs.getString("forwardBudgetDay", ""))
            ? prefs.getInt("forwardBudgetParts", 0) : 0;
    }
    static int subscription(Context context) {
        int selected = AlertService.prefs(context).getInt("forwardSimId", -1);
        return selected >= 0 ? selected : SubscriptionManager.getDefaultSmsSubscriptionId();
    }
    static List<SubscriptionInfo> sims(Context context) {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != 0) return Collections.emptyList();
        try {
            List<SubscriptionInfo> list = ((SubscriptionManager) context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)).getActiveSubscriptionInfoList();
            return list == null ? Collections.emptyList() : list;
        } catch (Exception error) { return Collections.emptyList(); }
    }
    static SmsManager sms(Context context) {
        int subscription = subscription(context);
        return subscription >= 0 ? SmsManager.getSmsManagerForSubscriptionId(subscription) : SmsManager.getDefault();
    }
    static String reason(Context context, int parts) {
        SharedPreferences prefs = AlertService.prefs(context);
        int selected = subscription(context);
        boolean simReady = selected >= 0;
        if (prefs.getInt("forwardSimId", -1) >= 0) {
            simReady = false;
            for (SubscriptionInfo sim : sims(context)) if (sim.getSubscriptionId() == selected) simReady = true;
        }
        boolean roamingKnown = false, roaming = false;
        try {
            TelephonyManager manager = (TelephonyManager) context.getSystemService(Context.TELEPHONY_SERVICE);
            if (Build.VERSION.SDK_INT >= 24 && selected >= 0) manager = manager.createForSubscriptionId(selected);
            roamingKnown = manager.getSimState() == TelephonyManager.SIM_STATE_READY
                && !manager.getNetworkOperator().isEmpty();
            roaming = manager.isNetworkRoaming();
        } catch (Exception ignored) { }
        return ForwardPolicy.blockReason(prefs.getBoolean("forwardEnabled", false), System.currentTimeMillis(),
            prefs.getLong("forwardPauseUntil", 0), prefs.getLong("forwardSessionUntil", 0),
            prefs.getBoolean("forwardBlockRoaming", false), roamingKnown, roaming, simReady,
            prefs.getInt("forwardDailyLimit", 0), used(context), parts);
    }
    /** Caller holds AlertService.LOCK. Reservations survive uncertain sends. */
    static boolean reserve(Context context, int parts) {
        return AlertService.prefs(context).edit().putString("forwardBudgetDay", day(System.currentTimeMillis()))
            .putInt("forwardBudgetParts", used(context) + parts).commit();
    }
    static String summary(Context context) {
        String blocked = reason(context, 1);
        int limit = AlertService.prefs(context).getInt("forwardDailyLimit", 0);
        return (blocked == null ? "Ready" : blocked) + " · " + used(context)
            + (limit > 0 ? " / " + limit : "") + " parts today";
    }
    static void togglePause(Context context) {
        synchronized (AlertService.LOCK) {
        SharedPreferences prefs = AlertService.prefs(context);
        if (!prefs.getBoolean("forwardEnabled", false)) return;
        boolean paused = prefs.getLong("forwardPauseUntil", 0) > System.currentTimeMillis();
        prefs.edit().putLong("forwardPauseUntil", paused ? 0 : Long.MAX_VALUE).commit();
        ActivityTimeline.record(context, paused ? "Forwarding pause cleared" : "Forwarding paused manually");
        PhoneWidget.updateAll(context);
        }
    }
}

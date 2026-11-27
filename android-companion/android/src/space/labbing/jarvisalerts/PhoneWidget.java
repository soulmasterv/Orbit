package space.labbing.jarvisalerts;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;

public class PhoneWidget extends AppWidgetProvider {
    static final String PAUSE = "space.labbing.jarvisalerts.WIDGET_PAUSE";
    static void updateAll(Context context) {
        AppWidgetManager manager = AppWidgetManager.getInstance(context);
        int[] ids = manager.getAppWidgetIds(new ComponentName(context, PhoneWidget.class));
        for (int id : ids) {
            RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.phone_widget);
            long checked = AlertService.prefs(context).getLong("lastServerAt", 0);
            String connection = checked == 0 ? "No check-in yet" : "Last check-in "
                + android.text.format.DateFormat.format("HH:mm", checked);
            views.setTextViewText(R.id.widget_status, connection + "\n" + ForwardControls.summary(context));
            boolean enabled = AlertService.prefs(context).getBoolean("forwardEnabled", false);
            boolean paused = AlertService.prefs(context).getLong("forwardPauseUntil", 0) > System.currentTimeMillis();
            views.setTextViewText(R.id.widget_pause, !enabled ? "Forwarding off" : paused ? "Clear pause" : "Pause forwarding");
            Intent open = new Intent(context, MainActivity.class);
            views.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, 700, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
            Intent toggle = new Intent(context, PhoneWidget.class).setAction(PAUSE);
            views.setOnClickPendingIntent(R.id.widget_pause, PendingIntent.getBroadcast(context, 701, toggle, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
            manager.updateAppWidget(id, views);
        }
    }
    @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) { updateAll(context); }
    @Override public void onReceive(Context context, Intent intent) {
        super.onReceive(context, intent);
        if (PAUSE.equals(intent.getAction())) ForwardControls.togglePause(context);
    }
}

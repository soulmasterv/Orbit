package space.labbing.jarvisalerts;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.BluetoothAdapter;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.view.View;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;

public class MainActivity extends Activity {
    private static final int BLUE = 0xff54a6ff, GREEN = 0xff61d1a1, AMBER = 0xffffc46b;
    private int background, surface, raised, border, foreground, muted;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final LinearLayout[] pages = new LinearLayout[4];
    private final TextView[] tabs = new TextView[4];
    private TextView title, status, statusDetail, connection, monitoringState, lastCheck;
    private TextView permissions, battery, health, sync, forwardingSummary;
    private TextView forwardResult, forwardTime, counts, destination, channel, channelDetail;
    private TextView bluetooth, pairingStatus, diagnostics, forwardControls;
    private LinearLayout history, pairingForm;
    private ScrollView scroll;
    private Button monitorButton, checkButton, pauseButton;
    private Switch forwardSwitch;
    private EditText keyInput;
    private int selected;
    private boolean updating;
    private String historySnapshot = "";
    private final Runnable refreshLoop = new Runnable() {
        @Override public void run() { refresh(); handler.postDelayed(this, 1500); }
    };

    private SharedPreferences prefs() { return AlertService.prefs(this); }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private boolean allowed(String permission) { return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED; }
    private boolean batteryExempt() {
        return ((PowerManager) getSystemService(POWER_SERVICE)).isIgnoringBatteryOptimizations(getPackageName());
    }
    private boolean fresh(long value, long window) {
        long age = System.currentTimeMillis() - value;
        return value > 0 && age >= 0 && age < window;
    }
    private GradientDrawable shape(int color, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(dp(radius));
        return drawable;
    }
    private LinearLayout column() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }
    private TextView text(String value, int size, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setLineSpacing(dp(3), 1);
        return view;
    }
    private void caption(LinearLayout parent, String value) {
        TextView view = text(value, 13, muted);
        view.setPadding(0, dp(6), 0, dp(4));
        parent.addView(view);
    }
    private void section(LinearLayout parent, String value) {
        TextView view = text(value, 18, foreground);
        view.setTypeface(null, Typeface.BOLD);
        view.setPadding(0, dp(10), 0, dp(10));
        parent.addView(view);
    }
    private LinearLayout card(LinearLayout parent) {
        LinearLayout view = column();
        view.setPadding(dp(16), dp(12), dp(16), dp(14));
        GradientDrawable drawable = shape(surface, 14);
        drawable.setStroke(dp(1), border);
        view.setBackground(drawable);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.bottomMargin = dp(12);
        parent.addView(view, params);
        return view;
    }
    private TextView row(LinearLayout parent, String label) {
        LinearLayout line = new LinearLayout(this);
        line.setGravity(android.view.Gravity.CENTER_VERTICAL);
        line.setPadding(0, dp(9), 0, dp(9));
        TextView name = text(label, 14, muted);
        TextView value = text("Checking", 14, foreground);
        value.setGravity(android.view.Gravity.END);
        line.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
        line.addView(value, new LinearLayout.LayoutParams(0, -2, 1.4f));
        parent.addView(line);
        return value;
    }
    private Button button(LinearLayout parent, String label, Runnable action, boolean primary) {
        Button view = new Button(this);
        view.setText(label);
        view.setAllCaps(false);
        view.setTextSize(14);
        view.setTextColor(primary ? 0xff080a0d : BLUE);
        view.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary ? BLUE : raised));
        view.setMinHeight(dp(48));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.topMargin = dp(6);
        parent.addView(view, params);
        view.setOnClickListener(v -> action.run());
        return view;
    }

    @Override public void onCreate(Bundle saved) {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        setTheme(dark ? android.R.style.Theme_Material_NoActionBar : android.R.style.Theme_Material_Light_NoActionBar);
        super.onCreate(saved);
        background = dark ? 0xff080a0d : 0xfff3f5f8;
        surface = dark ? 0xff15181e : 0xffffffff;
        raised = dark ? 0xff1c2128 : 0xffe8edf3;
        border = dark ? 0xff292e38 : 0xffdce1e8;
        foreground = dark ? 0xffeef2f8 : 0xff172333;
        muted = dark ? 0xffa4aebb : 0xff536174;
        getWindow().setStatusBarColor(background);
        getWindow().setNavigationBarColor(surface);
        if (!dark) getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        LinearLayout root = column();
        root.setBackgroundColor(background);
        TextView brand = text("ORBIT  /  PHONE", 12, BLUE);
        brand.setLetterSpacing(.15f);
        brand.setPadding(dp(20), dp(14), dp(20), dp(5));
        root.addView(brand);
        title = text("Status", 30, foreground);
        title.setTypeface(null, Typeface.BOLD);
        title.setPadding(dp(20), 0, dp(20), dp(12));
        root.addView(title);
        scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout content = column();
        content.setPadding(dp(16), 0, dp(16), dp(20));
        for (int index = 0; index < pages.length; index++) {
            pages[index] = column();
            content.addView(pages[index]);
        }
        scroll.addView(content);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        buildStatus();
        buildForwarding();
        buildAlerts();
        buildSettings();
        LinearLayout navigation = new LinearLayout(this);
        navigation.setBackgroundColor(surface);
        String[] labels = {"Status", "Forwarding", "Alerts", "Settings"};
        for (int index = 0; index < labels.length; index++) {
            final int tab = index;
            TextView view = text(labels[index], 13, muted);
            view.setGravity(android.view.Gravity.CENTER);
            view.setPadding(dp(2), dp(18), dp(2), dp(18));
            view.setMinHeight(dp(56));
            view.setOnClickListener(v -> select(tab));
            view.setContentDescription(labels[index] + " tab");
            navigation.addView(view, new LinearLayout.LayoutParams(0, -1, 1));
            tabs[index] = view;
        }
        root.addView(navigation, new LinearLayout.LayoutParams(-1, dp(60)));
        setContentView(root);
        select(saved == null ? 0 : saved.getInt("tab", 0));
        refresh();
    }

    private void select(int tab) {
        selected = Math.max(0, Math.min(3, tab));
        String[] labels = {"Status", "Forwarding", "Alerts", "Settings"};
        title.setText(labels[selected]);
        for (int index = 0; index < pages.length; index++) {
            pages[index].setVisibility(index == selected ? View.VISIBLE : View.GONE);
            tabs[index].setTextColor(index == selected ? BLUE : muted);
            tabs[index].setTypeface(null, index == selected ? Typeface.BOLD : Typeface.NORMAL);
            tabs[index].setSelected(index == selected);
        }
        scroll.scrollTo(0, 0);
    }

    private void buildStatus() {
        LinearLayout page = pages[0], hero = card(page);
        status = text("Checking connection", 25, foreground);
        status.setTypeface(null, Typeface.BOLD);
        hero.addView(status);
        statusDetail = text("", 14, muted);
        statusDetail.setPadding(0, dp(8), 0, dp(8));
        hero.addView(statusDetail);
        monitorButton = button(hero, "Start monitoring", this::toggleMonitoring, true);
        checkButton = button(hero, "Check connection now", this::checkNow, false);
        section(page, "Phone readiness");
        LinearLayout checks = card(page);
        connection = row(checks, "Server");
        lastCheck = row(checks, "Last check-in");
        monitoringState = row(checks, "Background service");
        permissions = row(checks, "SMS permissions");
        battery = row(checks, "Battery access");
        forwardingSummary = row(checks, "SMS forwarding");
        button(checks, "Fix permissions & battery access", () -> select(3), false);
        section(page, "Call system");
        LinearLayout calls = card(page);
        health = text("Waiting for a health report", 14, muted);
        calls.addView(health);
        sync = text("", 12, muted);
        sync.setPadding(0, dp(10), 0, 0);
        calls.addView(sync);
    }

    private void buildForwarding() {
        LinearLayout page = pages[1], setup = card(page);
        forwardSwitch = new Switch(this);
        forwardSwitch.setText("Forward incoming SMS");
        forwardSwitch.setTextSize(16);
        forwardSwitch.setTextColor(foreground);
        forwardSwitch.setMinHeight(dp(52));
        setup.addView(forwardSwitch);
        destination = row(setup, "Send to");
        caption(setup, "Uses the Samsung SIM and may incur SMS charges. New messages only.");
        forwardSwitch.setOnCheckedChangeListener((view, enabled) -> {
            if (updating) return;
            if (enabled) {
                updating = true;
                forwardSwitch.setChecked(false);
                updating = false;
                new AlertDialog.Builder(this).setTitle("Enable SMS forwarding?")
                    .setMessage("Forward new incoming messages to " + AlertService.DEST + ". Each message may use paid SIM credit. Long messages can use several SMS parts.")
                    .setNegativeButton("Cancel", (d, w) -> refresh())
                    .setPositiveButton("Enable", (d, w) -> enableForwarding()).show();
            } else {
                synchronized (AlertService.LOCK) { prefs().edit().putBoolean("forwardEnabled", false).commit(); }
                refresh();
            }
        });
        pauseButton = button(setup, "Pause for 30 minutes", this::toggleForwardPause, false);
        section(page, "Latest forward");
        LinearLayout latest = card(page);
        forwardResult = text("No forwarding activity yet", 20, foreground);
        latest.addView(forwardResult);
        forwardTime = text("", 13, muted);
        latest.addView(forwardTime);
        counts = row(latest, "Attempts / repeats skipped");
        caption(latest, "Sent means Android accepted the send. Only a delivery report confirms arrival. Carrier filtering can still block a message.");
        buildForwardExtras(page);
        section(page, "Recent forwards");
        history = column();
        page.addView(history);
        caption(page, "History contains times, SMS part counts and delivery results. It does not store message text or codes.");
        caption(page, "Messages from the forwarding destination and previously forwarded messages are skipped to prevent loops.");
    }

    private void buildForwardExtras(LinearLayout page) {
        section(page, "Forwarding controls");
        LinearLayout controls = card(page);
        forwardControls = text("", 14, muted);
        controls.addView(forwardControls);
        button(controls, "Preview SMS size & cost", () -> ForwardSettings.preview(this), false);
        button(controls, "Choose sending SIM", () -> ForwardSettings.sim(this), false);
        button(controls, "Daily limit & roaming", () -> ForwardSettings.limits(this), false);
        button(controls, "Set forwarding session", () -> ForwardSettings.session(this), false);
        caption(controls, "The daily limit counts forwarded SMS parts, including sends with an uncertain outcome.");
    }

    private void buildSettingsExtras(LinearLayout page) {
        section(page, "Pairing QR");
        LinearLayout qr = card(page);
        button(qr, "Import a pairing QR image", () -> {
            Intent choose = new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE);
            startActivityForResult(choose, 802);
        }, false);
        button(qr, "Display this phone’s pairing QR", () -> PairingQr.display(this), false);
        caption(qr, "Get the QR from your authenticated Orbit Phone controls, or another paired companion.");
        section(page, "Settings backup");
        LinearLayout backup = card(page);
        button(backup, "Export settings", () -> {
            Intent create = new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/json")
                .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, "Orbit-phone-settings.json");
            startActivityForResult(create, 800);
        }, false);
        button(backup, "Restore settings", () -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT)
            .setType("application/json").addCategory(Intent.CATEGORY_OPENABLE), 801), false);
        caption(backup, "Backups contain channel and spending preferences. Pairing keys, message history, quotas and device-specific SIM selection stay on this phone.");
        section(page, "Activity timeline");
        LinearLayout activity = card(page);
        button(activity, "View activity timeline", this::showTimeline, false);
        caption(activity, "Shows connection, settings and forwarding events. Message contents are excluded.");
        section(page, "Home-screen shortcuts");
        LinearLayout shortcuts = card(page);
        button(shortcuts, "Add home-screen widget", () -> {
            if (Build.VERSION.SDK_INT >= 26) {
                android.appwidget.AppWidgetManager manager = android.appwidget.AppWidgetManager.getInstance(this);
                if (manager.isRequestPinAppWidgetSupported()) {
                    manager.requestPinAppWidget(new android.content.ComponentName(this, PhoneWidget.class), null, null);
                    return;
                }
            }
            toast("Long-press Home, choose Widgets, then Orbit Phone.");
        }, false);
        caption(shortcuts, "To add the SMS forwarding Quick Settings tile, edit the notification shade and drag SMS forwarding into your tiles. Its pause button requires forwarding to be enabled first.");
    }

    private void showTimeline() {
        StringBuilder lines = new StringBuilder();
        try {
            JSONArray events = new JSONArray(prefs().getString("activityTimeline", "[]"));
            for (int i = 0; i < events.length(); i++) {
                JSONObject event = events.getJSONObject(i);
                lines.append(time(event.optLong("at"))).append("\n").append(event.optString("event")).append("\n\n");
            }
        } catch (Exception ignored) { }
        TextView view = text(lines.length() == 0 ? "No events recorded yet." : lines.toString(), 14, foreground);
        view.setPadding(dp(20), dp(12), dp(20), dp(12));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(view);
        new AlertDialog.Builder(this).setTitle("Activity timeline").setView(scroll).setPositiveButton("Done", null).show();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        try {
            if (request == 800) { CompanionBackup.write(this, uri); toast("Settings exported."); }
            if (request == 801) {
                JSONObject backup = CompanionBackup.read(this, uri);
                new AlertDialog.Builder(this).setTitle("Restore these preferences?")
                    .setMessage("Channel · " + backup.getString("channel") + "\nDaily part limit · " + backup.getInt("daily_parts")
                        + "\nRoaming protection · " + backup.getBoolean("block_roaming")
                        + "\nAn SMS channel can use paid SIM credit when monitoring is active.")
                    .setNegativeButton("Cancel", null).setPositiveButton("Restore", (d,w) -> {
                        try { CompanionBackup.restore(this, backup); refresh(); toast("Settings restored."); }
                        catch (Exception error) { toast("Restore failed. Check SMS permissions and the backup."); }
                    }).show();
            }
            if (request == 802) {
                toast("Reading QR image…");
                new Thread(() -> {
                    try {
                        JSONObject pairing = PairingQr.image(this, uri);
                        runOnUiThread(() -> {
                            if (isFinishing() || isDestroyed()) return;
                            new AlertDialog.Builder(this).setTitle("Use this phone pairing?")
                                .setMessage("This replaces the saved companion credential and device identity. Use a QR created by your own Orbit server or companion.")
                                .setNegativeButton("Cancel", null).setPositiveButton("Use pairing", (d,w) -> {
                                    if (prefs().getBoolean("enabled", false)) { toast("Pause monitoring before replacing pairing."); return; }
                                    prefs().edit().putString("key", pairing.optString("key"))
                                        .putString("device", pairing.optString("device")).remove("lastConnectionError")
                                        .putLong("lastServerAt", 0).commit();
                                    ActivityTimeline.record(this, "Pairing imported from QR");
                                    refresh();
                                    toast("Pairing saved. Start monitoring from Status.");
                                }).show();
                        });
                    } catch (Exception error) { runOnUiThread(() -> toast("No valid Orbit pairing QR found in that image.")); }
                }, "orbit-qr-import").start();
            }
        } catch (Exception error) { toast("The file could not be read or written."); }
    }

    private void buildAlerts() {
        LinearLayout page = pages[2], selected = card(page);
        channel = text("Web notifications", 22, foreground);
        selected.addView(channel);
        channelDetail = text("", 14, muted);
        channelDetail.setPadding(0, dp(8), 0, dp(10));
        selected.addView(channelDetail);
        button(selected, "Choose notification channel", this::chooseChannel, true);
        caption(selected, "This controls server alerts. Incoming SMS forwarding has its own switch.");
        section(page, "Delivery information");
        LinearLayout info = card(page);
        caption(info, "Web notifications use the subscription already paired on the server.");
        caption(info, "WhatsApp uses web notifications when the gateway is unavailable.");
        caption(info, "SMS alerts use SIM credit. Unconfirmed alert delivery can use the serverâ€™s web fallback.");
        button(info, "View connection diagnostics", () -> { select(3); diagnostics.setVisibility(View.VISIBLE); }, false);
    }

    private void buildSettings() {
        LinearLayout page = pages[3];
        section(page, "Pairing");
        LinearLayout pair = card(page);
        pairingStatus = row(pair, "Companion key");
        button(pair, "Set or replace key", () -> pairingForm.setVisibility(pairingForm.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE), false);
        pairingForm = column();
        keyInput = new EditText(this);
        keyInput.setHint("64-character companion key");
        keyInput.setHintTextColor(muted);
        keyInput.setTextColor(foreground);
        keyInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        keyInput.setSingleLine(true);
        keyInput.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        pairingForm.addView(keyInput, new LinearLayout.LayoutParams(-1, dp(56)));
        button(pairingForm, "Save key", () -> {
            String key = keyInput.getText().toString().trim();
            if (!key.matches("[a-f0-9]{64}")) { toast("Enter the 64-character companion key."); return; }
            prefs().edit().putString("key", key).remove("lastConnectionError").commit();
            keyInput.setText("");
            pairingForm.setVisibility(View.GONE);
            toast("Key saved. Start monitoring from Status.");
            refresh();
        }, true);
        pair.addView(pairingForm);
        pairingForm.setVisibility(prefs().getString("key", "").isEmpty() ? View.VISIBLE : View.GONE);
        section(page, "Android permissions");
        LinearLayout access = card(page);
        button(access, "Grant SMS permissions", () -> requestPermissions(new String[]{Manifest.permission.SEND_SMS, Manifest.permission.RECEIVE_SMS}, 6), false);
        button(access, "Allow background monitoring", this::openBattery, false);
        button(access, "Open app settings", this::openAppSettings, false);
        caption(access, "On Samsung, add Orbit Phone to Never sleeping apps. Reopen the app after a force stop.");
        section(page, "Bluetooth");
        LinearLayout bt = card(page);
        bluetooth = row(bt, "Phone Bluetooth");
        button(bt, "Open Bluetooth settings", () -> open(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS)), false);
        section(page, "Connection diagnostics");
        LinearLayout tools = card(page);
        button(tools, "Open internet settings", () -> open(new Intent(Settings.ACTION_WIRELESS_SETTINGS)), false);
        button(tools, "Open Private DNS settings", () -> open(new Intent("android.settings.PRIVATE_DNS_SETTINGS")), false);
        button(tools, "Show / hide diagnostics", () -> diagnostics.setVisibility(diagnostics.getVisibility() == View.VISIBLE ? View.GONE : View.VISIBLE), false);
        diagnostics = text("", 13, muted);
        diagnostics.setTextIsSelectable(true);
        diagnostics.setPadding(0, dp(10), 0, 0);
        tools.addView(diagnostics);
        diagnostics.setVisibility(View.GONE);
        caption(page, "Orbit Phone Â· " + version() + "\nExisting JARVIS server and companion pairing");
    }

    private void chooseChannel() {
        String[] names = {"Web notifications", "WhatsApp", "SMS Â· uses SIM credit"};
        String[] values = {"web", "whatsapp", "sms"};
        String current = prefs().getString("notificationMode", "web");
        int checked = current.equals("sms") ? 2 : current.equals("whatsapp") ? 1 : 0;
        new AlertDialog.Builder(this).setTitle("Notification channel").setSingleChoiceItems(names, checked, (dialog, index) -> {
            dialog.dismiss();
            if (index == 2) {
                new AlertDialog.Builder(this).setTitle("Use paid SMS alerts?")
                    .setMessage("Server alerts will use the Samsung SIM. Incoming SMS forwarding is configured separately.")
                    .setNegativeButton("Cancel", null).setPositiveButton("Use SMS", (d, w) -> {
                        if (!allowed(Manifest.permission.SEND_SMS)) { requestPermissions(new String[]{Manifest.permission.SEND_SMS}, 6); return; }
                        setChannel(values[index]);
                    }).show();
            } else setChannel(values[index]);
        }).setNegativeButton("Cancel", null).show();
    }
    private void setChannel(String value) {
        synchronized (AlertService.LOCK) { prefs().edit().putString("notificationMode", value).putBoolean("channelSynced", false).commit(); }
        refresh();
    }
    private void enableForwarding() {
        if (!allowed(Manifest.permission.SEND_SMS) || !allowed(Manifest.permission.RECEIVE_SMS)) {
            requestPermissions(new String[]{Manifest.permission.SEND_SMS, Manifest.permission.RECEIVE_SMS}, 5);
            return;
        }
        synchronized (AlertService.LOCK) { prefs().edit().putBoolean("forwardEnabled", true).putLong("forwardPauseUntil", 0).putLong("forwardSessionUntil",0).commit(); }
        refresh();
    }
    private void toggleForwardPause() {
        synchronized (AlertService.LOCK) {
        long until = prefs().getLong("forwardPauseUntil", 0);
        prefs().edit().putLong("forwardPauseUntil", until > System.currentTimeMillis() ? 0 : System.currentTimeMillis() + 1800000).commit();
        }
        refresh();
    }
    private void toggleMonitoring() {
        if (prefs().getBoolean("enabled", false)) {
            prefs().edit().putBoolean("enabled", false).commit();
            stopService(new Intent(this, AlertService.class));
            KeepAliveJob.cancel(this);
        } else {
            if (prefs().getString("key", "").isEmpty()) { select(3); pairingForm.setVisibility(View.VISIBLE); toast("Add your companion key first."); return; }
            if (prefs().getString("notificationMode", "web").equals("sms") && !allowed(Manifest.permission.SEND_SMS)) {
                requestPermissions(new String[]{Manifest.permission.SEND_SMS}, 6); return;
            }
            prefs().edit().putBoolean("enabled", true).commit();
            launch(false);
        }
        refresh();
    }
    private void checkNow() {
        if (!prefs().getBoolean("enabled", false)) { toast("Start monitoring to check the server."); return; }
        launch(true);
        toast("Connection check queued.");
    }
    private void launch(boolean refresh) {
        try {
            Intent intent = new Intent(this, AlertService.class);
            if (refresh) intent.setAction("space.labbing.jarvisalerts.REFRESH");
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent); else startService(intent);
        } catch (Exception e) { prefs().edit().putString("lastConnectionError", "BackgroundStartRestricted").apply(); }
    }

    private void refresh() {
        ActivityTimeline.observe(this);
        if (status == null) return;
        boolean paired = !prefs().getString("key", "").isEmpty();
        boolean enabled = prefs().getBoolean("enabled", false);
        boolean online = enabled && fresh(prefs().getLong("lastServerAt", 0), 25000);
        boolean running = enabled && fresh(prefs().getLong("lastServiceAt", 0), 25000);
        boolean checking = prefs().getBoolean("connectionChecking", false) && running;
        String error = prefs().getString("lastConnectionError", "");
        status.setText(!paired ? "Pair your phone" : !enabled ? "Monitoring paused" : online ? "Connected" : checking ? "Connectingâ€¦" : "Connection needs attention");
        status.setTextColor(online ? GREEN : !enabled ? muted : AMBER);
        statusDetail.setText(!paired ? "Add the companion key in Settings to connect to Ubuntu." : !enabled ? "Server alerts are paused. SMS forwarding has its own switch." : online ? "The companion is checking in with Ubuntu." : connectionHelp(error));
        monitorButton.setText(enabled ? "Pause monitoring" : "Start monitoring");
        checkButton.setEnabled(enabled && !checking);
        connection.setText(online ? "Connected" : checking ? "Checkingâ€¦" : enabled ? "Unavailable" : "Paused");
        lastCheck.setText(age(prefs().getLong("lastServerAt", 0)));
        monitoringState.setText(running ? "Running" : enabled ? "Needs attention" : "Paused");
        permissions.setText(allowed(Manifest.permission.SEND_SMS) && allowed(Manifest.permission.RECEIVE_SMS) ? "Granted" : "Setup needed");
        battery.setText(batteryExempt() ? "Unrestricted" : "Optimization enabled");
        boolean forwarding = prefs().getBoolean("forwardEnabled", false);
        long pauseUntil = prefs().getLong("forwardPauseUntil", 0);
        boolean paused = pauseUntil > System.currentTimeMillis();
        forwardingSummary.setText(ForwardControls.reason(this, 1) == null ? "On" : ForwardControls.reason(this, 1));
        updating = true;
        forwardSwitch.setChecked(forwarding);
        updating = false;
        destination.setText(AlertService.DEST);
        pauseButton.setEnabled(forwarding);
        pauseButton.setText(paused ? "Resume forwarding" : "Pause for 30 minutes");
        long at = prefs().getLong("lastForwardAt", 0);
        String result = prefs().getString("lastForwardResult", "");
        forwardResult.setText(!forwarding ? "Forwarding is off" : paused ? pauseUntil == Long.MAX_VALUE ? "Paused until resumed" : "Paused until " + time(pauseUntil) : !allowed(Manifest.permission.SEND_SMS) || !allowed(Manifest.permission.RECEIVE_SMS) ? "SMS permission needed" : at == 0 ? "Waiting for a new SMS" : result.isEmpty() ? prefs().getString("forwardStatus", "Result unavailable") : ForwardHistory.label(result));
        forwardTime.setText(at == 0 ? "" : time(at) + " Â· " + prefs().getInt("lastForwardParts", 0) + " SMS part(s)");
        counts.setText(prefs().getInt("forwardAttempts", 0) + " / " + prefs().getInt("forwardSuppressed", 0));
        forwardControls.setText(ForwardControls.summary(this));
        renderHistory();
        renderHealth(online);
        String mode = prefs().getString("notificationMode", "web");
        channel.setText(mode.equals("sms") ? "SMS alerts" : mode.equals("whatsapp") ? "WhatsApp" : "Web notifications");
        channelDetail.setText(!prefs().getBoolean("channelSynced", false) ? "Waiting to sync with Ubuntu." : mode.equals("whatsapp") ? prefs().getBoolean("whatsappReady", false) ? "Gateway connected. Web fallback available." : "Gateway unavailable. Server uses web fallback." : mode.equals("sms") ? "Paid alert SMS enabled." : "Server alerts use your paired web subscription.");
        pairingStatus.setText(paired ? "Saved on this phone" : "Setup needed");
        try {
            BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
            bluetooth.setText(adapter == null ? "Unavailable" : adapter.isEnabled() ? "On" : "Off");
        } catch (Exception e) { bluetooth.setText("Check Android settings"); }
        diagnostics.setText("Companion " + version() + "\nMonitoring service Â· " + (running ? "running" : "inactive") + "\nServer check-in Â· " + age(prefs().getLong("lastServerAt", 0)) + "\nLast connection error Â· " + (error.isEmpty() ? "none" : error) + "\n" + connectionHelp(error) + "\n" + prefs().getString("pilotStatus", "No remote changes received") + "\nLatest general SMS result Â· " + prefs().getString("lastSmsStatus", "none"));
    }

    private void renderHistory() {
        String snapshot = prefs().getString("forwardHistory", "[]");
        if (snapshot.equals(historySnapshot)) return;
        historySnapshot = snapshot;
        history.removeAllViews();
        try {
            JSONArray entries = new JSONArray(snapshot);
            if (entries.length() == 0) caption(history, "New forwards will appear here after this update.");
            for (int index = 0; index < entries.length(); index++) {
                JSONObject entry = entries.getJSONObject(index);
                LinearLayout view = card(history);
                String state = entry.optString("status");
                view.addView(text(ForwardHistory.label(state), 15, state.equals("delivered") ? GREEN : state.equals("failed") ? AMBER : foreground));
                caption(view, time(entry.optLong("at")) + " Â· " + entry.optInt("parts") + " SMS part(s)");
                if (state.equals("submitted")) caption(view, "The carrier has not confirmed arrival.");
                if (state.equals("failed")) caption(view, smsError(entry.optInt("error")));
            }
        } catch (Exception e) { caption(history, "Forwarding history unavailable."); }
    }
    private void renderHealth(boolean online) {
        long checked = prefs().getLong("healthAt", 0);
        if (!online || !fresh(checked, 60000)) {
            health.setText(online ? "Health report is stale. Check the Ubuntu monitor." : "Waiting for a fresh server health report.");
            health.setTextColor(muted);
        } else {
            try {
                JSONArray issues = new JSONArray(prefs().getString("healthIssues", "[]"));
                StringBuilder value = new StringBuilder();
                for (int index = 0; index < issues.length(); index++) {
                    if (index > 0) value.append("\n");
                    value.append(issues.getString(index));
                }
                health.setText(issues.length() == 0 ? "Call-system checks passing" : value);
                health.setTextColor(issues.length() == 0 ? GREEN : AMBER);
            } catch (Exception e) { health.setText("Health report unavailable"); }
        }
        sync.setText("Health checked " + age(checked));
    }
    private String connectionHelp(String error) {
        switch (error) {
            case "HTTP 401": case "HTTP 403": return "The server rejected pairing. Check the companion key in Settings.";
            case "HTTP 404": return "The companion route is missing. Check the Ubuntu deployment.";
            case "UnknownHostException": return "DNS lookup failed. Check internet and Private DNS in Settings.";
            case "SocketTimeoutException": return "The server timed out. Check internet and Private DNS. A DNS provider can return an unreachable server address.";
            case "SSLHandshakeException": return "Secure connection failed. Check the phone date and server certificate.";
            case "BackgroundStartRestricted": return "Android restricted background startup. Reopen the app and allow background monitoring.";
            case "": return "Waiting for a connection check.";
            default: return error.startsWith("HTTP 5") ? "The server is unavailable. Check Ubuntuâ€™s school-api service." : "Connection failed. Open diagnostics for the recorded error.";
        }
    }
    private String smsError(int error) {
        switch (error) {
            case 2: return "Radio is off. Check mobile service.";
            case 3: return "The modem rejected the message format.";
            case 4: return "No mobile service available.";
            case 5: return "Androidâ€™s SMS sending limit was reached.";
            case 0: return "The send could not be completed. Check the SIM and permissions.";
            default: return "Carrier or modem rejected sending. Result code " + error + ".";
        }
    }
    private String version() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; }
        catch (Exception e) { return "Version unavailable"; }
    }
    private String time(long at) { return android.text.format.DateFormat.format("dd MMM, HH:mm", at).toString(); }
    private String age(long at) {
        if (at <= 0) return "Never";
        long seconds = Math.max(0, (System.currentTimeMillis() - at) / 1000);
        if (seconds < 60) return seconds + "s ago";
        if (seconds < 3600) return seconds / 60 + "m ago";
        return time(at);
    }
    private void open(Intent intent) { try { startActivity(intent); } catch (Exception e) { toast("Open this setting in Android Settings."); } }
    private void openAppSettings() { open(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))); }
    private void openBattery() {
        if (batteryExempt()) { toast("Background monitoring is already unrestricted."); return; }
        open(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())));
    }
    private void toast(String value) { Toast.makeText(this, value, Toast.LENGTH_LONG).show(); }
    @Override protected void onResume() {
        super.onResume();
        if (prefs().getBoolean("enabled", false) && !prefs().getString("key", "").isEmpty()) launch(false);
        handler.removeCallbacks(refreshLoop);
        handler.post(refreshLoop);
    }
    @Override protected void onPause() { handler.removeCallbacks(refreshLoop); super.onPause(); }
    @Override protected void onSaveInstanceState(Bundle saved) { saved.putInt("tab", selected); super.onSaveInstanceState(saved); }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == 7 && allowed(Manifest.permission.READ_PHONE_STATE)) ForwardSettings.sim(this);
        if (request == 5 && allowed(Manifest.permission.SEND_SMS) && allowed(Manifest.permission.RECEIVE_SMS)) enableForwarding();
        refresh();
    }
}

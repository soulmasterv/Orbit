package space.labbing.jarvisalerts;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.telephony.SubscriptionInfo;
import android.text.InputType;
import android.widget.*;
import java.math.BigDecimal;
import java.util.*;

final class ForwardSettings {
    static void session(Activity activity) {
        String[] options = {"For one hour", "Until tonight", "Until manually stopped"};
        new AlertDialog.Builder(activity).setTitle("Forwarding session").setItems(options, (dialog, which) -> {
            long until = 0;
            if (which == 0) until = System.currentTimeMillis() + 3600000;
            if (which == 1) {
                Calendar end = Calendar.getInstance();
                end.set(Calendar.HOUR_OF_DAY, 23); end.set(Calendar.MINUTE, 59); end.set(Calendar.SECOND, 59);
                until = end.getTimeInMillis();
            }
            synchronized (AlertService.LOCK) { AlertService.prefs(activity).edit().putLong("forwardSessionUntil", until).commit(); }
            ActivityTimeline.record(activity, "Forwarding session changed");
            PhoneWidget.updateAll(activity);
        }).setNegativeButton("Cancel", null).show();
    }
    static void limits(Activity activity) {
        SharedPreferences prefs = AlertService.prefs(activity);
        LinearLayout form = new LinearLayout(activity);
        form.setOrientation(LinearLayout.VERTICAL);
        int pad = Math.round(20 * activity.getResources().getDisplayMetrics().density);
        form.setPadding(pad, 0, pad, 0);
        TextView help = new TextView(activity);
        help.setText("Daily limit applies to forwarded SMS parts. Zero means unlimited. A price per part enables an estimate in your SIM’s currency.");
        form.addView(help);
        EditText limit = new EditText(activity);
        limit.setInputType(InputType.TYPE_CLASS_NUMBER);
        limit.setHint("Maximum SMS parts per day");
        limit.setText(String.valueOf(prefs.getInt("forwardDailyLimit", 0)));
        form.addView(limit);
        EditText price = new EditText(activity);
        price.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
        price.setHint("Price per SMS part");
        price.setText(BigDecimal.valueOf(prefs.getLong("forwardPartPriceMils", 0), 3).toPlainString());
        form.addView(price);
        Switch roaming = new Switch(activity);
        roaming.setText("Pause forwarding while roaming");
        roaming.setChecked(prefs.getBoolean("forwardBlockRoaming", false));
        form.addView(roaming);
        AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("SIM spending controls").setView(form)
            .setNegativeButton("Cancel", null).setPositiveButton("Save", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            try {
                int parts = Integer.parseInt(limit.getText().toString());
                long mils = new BigDecimal(price.getText().toString()).movePointRight(3).longValueExact();
                if (parts < 0 || parts > 10000 || mils < 0 || mils > 100000000) throw new IllegalArgumentException();
                synchronized (AlertService.LOCK) {
                    prefs.edit().putInt("forwardDailyLimit", parts).putLong("forwardPartPriceMils", mils)
                        .putBoolean("forwardBlockRoaming", roaming.isChecked()).commit();
                }
                ActivityTimeline.record(activity, "Forwarding spending controls changed");
                PhoneWidget.updateAll(activity);
                dialog.dismiss();
            } catch (Exception error) { Toast.makeText(activity, "Enter a limit from 0 to 10000 and a non-negative price with up to 3 decimals.", Toast.LENGTH_LONG).show(); }
        }));
        dialog.show();
    }
    static void sim(Activity activity) {
        if (activity.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != 0) {
            new AlertDialog.Builder(activity).setTitle("Show available SIMs?")
                .setMessage("Android requires Phone permission to list installed SIMs. Orbit uses it to select a sending SIM.")
                .setNegativeButton("Cancel", null).setPositiveButton("Continue", (d,w) -> activity.requestPermissions(new String[]{Manifest.permission.READ_PHONE_STATE}, 7)).show();
            return;
        }
        List<SubscriptionInfo> sims = ForwardControls.sims(activity);
        String[] names = new String[sims.size() + 1];
        names[0] = "Android default SMS SIM";
        for (int i = 0; i < sims.size(); i++) names[i + 1] = "SIM " + (sims.get(i).getSimSlotIndex() + 1) + " · " + sims.get(i).getDisplayName();
        new AlertDialog.Builder(activity).setTitle("Sending SIM for forwards").setItems(names, (d,index) -> {
            synchronized (AlertService.LOCK) {
                AlertService.prefs(activity).edit().putInt("forwardSimId", index == 0 ? -1 : sims.get(index - 1).getSubscriptionId()).commit();
            }
            ActivityTimeline.record(activity, "Forwarding SIM selection changed");
        }).setNegativeButton("Cancel", null).show();
    }
    static void preview(Activity activity) {
        LinearLayout form = new LinearLayout(activity);
        form.setOrientation(LinearLayout.VERTICAL);
        int pad = Math.round(20 * activity.getResources().getDisplayMetrics().density);
        form.setPadding(pad,0,pad,0);
        EditText sample = new EditText(activity);
        sample.setHint("Type sample message text");
        sample.setMinLines(3);
        form.addView(sample);
        new AlertDialog.Builder(activity).setTitle("Forwarding size preview").setView(form)
            .setNegativeButton("Cancel", null).setPositiveButton("Estimate", (d,w) -> {
                String body = "[Forwarded SMS]\nMessage from Sample sender\n" + sample.getText();
                try {
                    int parts = ForwardControls.sms(activity).divideMessage(body).size();
                    long mils = AlertService.prefs(activity).getLong("forwardPartPriceMils", 0);
                    String cost = mils > 0 ? "\nEstimated cost · " + BigDecimal.valueOf(mils * parts, 3).stripTrailingZeros().toPlainString()
                        + " in your configured SIM currency." : "\nSet a price per part in spending controls for a cost estimate.";
                    new AlertDialog.Builder(activity).setTitle(parts + " SMS part(s)")
                        .setMessage("Estimate includes the forwarding header and a sample sender. Actual sender length and carrier billing can change the total." + cost)
                        .setPositiveButton("Done", null).show();
                } catch (Exception error) { Toast.makeText(activity, "SMS sizing is unavailable on this device.", Toast.LENGTH_LONG).show(); }
            }).show();
    }
}

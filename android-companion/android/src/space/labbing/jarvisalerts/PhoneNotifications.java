package space.labbing.jarvisalerts;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.widget.*;
import org.json.*;
import java.text.SimpleDateFormat;
import java.util.*;

final class PhoneNotifications {
    static String delivery(Activity a) { return AlertService.prefs(a).getString("phoneAlertDelivery", "web"); }
    static boolean fallback(Activity a) { return AlertService.prefs(a).getBoolean("phoneAlertFallback", true); }
    static String channel(String value) { return "sms".equals(value) ? "SMS" : "web".equals(value) ? "Orbit" : "None yet"; }
    static void settings(Activity a) {
        LinearLayout box = new LinearLayout(a); box.setOrientation(LinearLayout.VERTICAL); box.setPadding(32,16,32,16);
        Button choice = new Button(a); choice.setText("Delivery: " + channel(delivery(a))); box.addView(choice);
        Switch fallback = new Switch(a); fallback.setText("Use Orbit if SMS fails"); fallback.setChecked(fallback(a)); box.addView(fallback);
        TextView info = new TextView(a); info.setPadding(0,20,0,16);
        info.setText("Applies to phone-service errors, recoveries, incoming-call notices and companion health alerts.\n\n"
            + "Errors and recoveries share an incident and delivery channel. Recovery is sent only after its error was sent. Changing Delivery applies to new incidents.\n\n"
            + "Samsung, SIM and SMS-permission outages cannot reliably notify through SMS. With fallback off, Orbit will not be used automatically.\n\n"
            + "If fallback is needed, Orbit receives the incident error before its recovery. SMS uses SIM credit. Incoming SMS forwarding is separate.\n\n"
            + (AlertService.prefs(a).getBoolean("phoneAlertSynced",false) ? "Choice synced with Ubuntu." : "Choice pending: start monitoring and connect to Ubuntu.")); box.addView(info);
        choice.setOnClickListener(v -> choose(a,choice));
        fallback.setOnCheckedChangeListener((v,on) -> save(a,null,on));
        ScrollView scroll = new ScrollView(a); scroll.addView(box);
        new AlertDialog.Builder(a).setTitle("Phone alerts").setView(scroll).setPositiveButton("Done",null).show();
    }
    private static void choose(Activity a, Button choice) {
        String[] values = {"web","sms"};
        new AlertDialog.Builder(a).setTitle("Delivery").setSingleChoiceItems(new String[]{"Orbit","SMS - uses SIM credit"},
            "sms".equals(delivery(a))?1:0,(dialog,index)->{
                dialog.dismiss();
                if(index==1) {
                    new AlertDialog.Builder(a).setTitle("Use SMS for phone alerts?")
                        .setMessage("This sends chargeable SMS for new phone incidents and call notices. SMS forwarding stays separate.")
                        .setNegativeButton("Cancel",null).setPositiveButton("Use SMS",(d,w)->{
                            if(a.checkSelfPermission(Manifest.permission.SEND_SMS)!=0) {
                                a.requestPermissions(new String[]{Manifest.permission.SEND_SMS},6);
                                Toast.makeText(a,"Grant permission, then choose SMS again.",Toast.LENGTH_LONG).show(); return;
                            }
                            save(a,values[index],null); choice.setText("Delivery: SMS");
                        }).show();
                } else {save(a,values[index],null);choice.setText("Delivery: Orbit");}
            }).setNegativeButton("Cancel",null).show();
    }
    private static void save(Activity a,String delivery,Boolean fallback) {
        synchronized(AlertService.LOCK) {
            SharedPreferences.Editor edit=AlertService.prefs(a).edit().putBoolean("phoneAlertSynced",false);
            if(delivery!=null) edit.putString("phoneAlertDelivery",delivery);
            if(fallback!=null) edit.putBoolean("phoneAlertFallback",fallback);
            edit.commit(); ActivityTimeline.record(a,"Phone notification preference changed");
        }
        if(AlertService.prefs(a).getBoolean("enabled",false)) a.startForegroundService(new Intent(a,AlertService.class).setAction("space.labbing.jarvisalerts.REFRESH"));
    }
    static void history(Activity a,LinearLayout box) {
        box.removeAllViews();
        JSONArray items;
        try {items=new JSONArray(AlertService.prefs(a).getString("phoneNotificationHistory","[]"));}catch(Exception e){items=new JSONArray();}
        if(items.length()==0) {TextView empty=new TextView(a);empty.setText("No phone alerts recorded yet. History updates while monitoring is connected.");empty.setTextColor(Color.LTGRAY);box.addView(empty);return;}
        for(int i=0;i<items.length();i++) {
            JSONObject item=items.optJSONObject(i);if(item==null)continue;
            TextView row=new TextView(a);row.setTextColor(Color.LTGRAY);row.setTextSize(14);row.setPadding(0,16,0,20);
            String incident=item.optString("incident","");if(incident.length()>8)incident=incident.substring(0,8);
            String actual=item.isNull("actual")?null:item.optString("actual");
            String status=item.optString("status","pending").replace('_',' ');
            if(status.equals("accepted"))status="accepted by Orbit push service; receipt not confirmed";
            if(status.equals("submitted"))status="SMS sent; delivery not confirmed";
            row.setText(new SimpleDateFormat("dd MMM HH:mm",Locale.getDefault()).format(new Date((long)(item.optDouble("created",0)*1000)))
                +"  "+item.optString("category").replace('_',' ')+" / "+item.optString("phase")
                +"\nIncident "+incident+"\n"+item.optString("summary")
                +"\nChosen: "+channel(item.optString("chosen"))+" | Actual: "+channel(actual)+"\nStatus: "+status);
            box.addView(row);
        }
    }
}

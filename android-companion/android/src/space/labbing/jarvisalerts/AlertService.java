package space.labbing.jarvisalerts;

import android.app.*;

import android.content.*;

import android.os.*;

import android.telephony.SmsManager;

import org.json.*;

import javax.net.ssl.HttpsURLConnection;

import java.net.URL;

import java.io.*;

import java.nio.charset.StandardCharsets;

import java.util.*;

import java.util.concurrent.*;



public class AlertService extends Service {

    static final Object LOCK=new Object();

    static final String DEST="01011288486",ENDPOINT="https://school-api.admin-ai.site/api/jarvis-phone-alerts/poll";

    PowerManager.WakeLock wake;
    ScheduledExecutorService loop;int failures=0,staleSamples=0;boolean unreachable=false,stale=false;

    static android.content.SharedPreferences prefs(Context c){return c.getSharedPreferences("alerts",0);}

    static JSONObject object(String s){try{return new JSONObject(s);}catch(Exception e){return new JSONObject();}}

    static void ack(Context c,String id,String status){synchronized(LOCK){

        JSONObject terminal=object(prefs(c).getString("terminalResults","{}"));String prior=terminal.optString(id);

        if("delivered".equals(prior)||("failed".equals(prior)&&"submitted".equals(status)))return;

        JSONObject a=object(prefs(c).getString("acks","{}"));try{a.put(id,status);terminal.put(id,status);while(terminal.length()>256){String k=terminal.keys().next();terminal.remove(k);}}catch(Exception ignored){}

        prefs(c).edit().putString("acks",a.toString()).putString("terminalResults",terminal.toString()).putString("lastSmsStatus",status).putLong("lastSmsAt",System.currentTimeMillis()).commit();

    }}

    public void onCreate(){super.onCreate();

        KeepAliveJob.schedule(this);
        PowerManager pm=(PowerManager)getSystemService(POWER_SERVICE);wake=pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"JARVIS:PluggedMonitoring");wake.setReferenceCounted(false);
        maintainWake();
        unreachable=prefs(this).getBoolean("unreachable",false);stale=prefs(this).getBoolean("stale",false);

        if(Build.VERSION.SDK_INT>=26)((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(new NotificationChannel("watch","Orbit Phone connection",NotificationManager.IMPORTANCE_LOW));

        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"watch"):new Notification.Builder(this);

        startForeground(7,b.setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("Orbit Phone is monitoring").setContentText("Monitoring active / delivery follows your channel choice").setOngoing(true).build());

        loop=Executors.newSingleThreadScheduledExecutor();loop.scheduleWithFixedDelay(()->{try{tick();}catch(Exception e){status("Companion check failed; no automatic SMS replay.");}},0,5,TimeUnit.SECONDS);

    }

    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!prefs(this).getBoolean("enabled", false)) { stopSelf(); return START_NOT_STICKY; }
        KeepAliveJob.schedule(this);
        if (intent != null && "space.labbing.jarvisalerts.REFRESH".equals(intent.getAction()) && loop != null && !loop.isShutdown()) {
            if (System.currentTimeMillis() - prefs(this).getLong("lastManualCheckAt", 0) > 5000) {
                prefs(this).edit().putLong("lastManualCheckAt", System.currentTimeMillis()).apply();
                loop.execute(() -> { try { tick(); } catch (Exception error) { status("Connection check unavailable."); } });
            }
        }
        return START_STICKY;
    }
    public void onTaskRemoved(Intent i){KeepAliveJob.schedule(this);super.onTaskRemoved(i);}
    void maintainWake(){Intent battery=registerReceiver(null,new IntentFilter(Intent.ACTION_BATTERY_CHANGED));boolean plugged=battery!=null&&battery.getIntExtra(BatteryManager.EXTRA_PLUGGED,0)!=0;if(plugged&&prefs(this).getBoolean("enabled",false))wake.acquire(120000);else if(wake.isHeld())wake.release();}

    public IBinder onBind(Intent i){return null;}

    public void onDestroy(){if(wake!=null&&wake.isHeld())wake.release();prefs(this).edit().putLong("lastServiceAt",0).apply();if(loop!=null)loop.shutdownNow();super.onDestroy();}

    void status(String s){prefs(this).edit().putString("status",s).apply();}

    JSONObject request(JSONObject body)throws Exception{

        HttpsURLConnection c=(HttpsURLConnection)new URL(ENDPOINT).openConnection();c.setInstanceFollowRedirects(false);c.setConnectTimeout(4500);c.setReadTimeout(4500);c.setRequestMethod("POST");c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");c.setRequestProperty("X-Jarvis-Phone-Key",prefs(this).getString("key",""));

        prefs(this).edit().putBoolean("connectionChecking", true).apply();
        try{byte[] data=body.toString().getBytes(StandardCharsets.UTF_8);c.setFixedLengthStreamingMode(data.length);try(OutputStream o=c.getOutputStream()){o.write(data);}int code=c.getResponseCode();if(code!=200)throw new IOException("HTTP "+code);ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=c.getInputStream()){byte[] buf=new byte[2048];int n;while((n=in.read(buf))!=-1){out.write(buf,0,n);if(out.size()>98304)throw new IOException("Oversize response");}}return new JSONObject(out.toString("UTF-8"));}finally{c.disconnect();prefs(this).edit().putBoolean("connectionChecking", false).apply();}

    }

    JSONObject diagnostics() throws Exception {
        boolean send = checkSelfPermission(android.Manifest.permission.SEND_SMS) == 0;
        boolean receive = checkSelfPermission(android.Manifest.permission.RECEIVE_SMS) == 0;
        android.telephony.TelephonyManager phone = (android.telephony.TelephonyManager)getSystemService(TELEPHONY_SERVICE);
        boolean sim = phone.getSimState() == android.telephony.TelephonyManager.SIM_STATE_READY;
        return new JSONObject().put("version",1).put("sms_permissions",send&&receive).put("sms_send_permission",send)
            .put("sim_ready",sim).put("forward_enabled",prefs(this).getBoolean("forwardEnabled",false));
    }

    void tick()throws Exception{
        ActivityTimeline.observe(this);
        maintainWake();

        prefs(this).edit().putLong("lastServiceAt",System.currentTimeMillis()).apply();

        if(!prefs(this).getBoolean("enabled",false)){stopSelf();return;}

        String device=prefs(this).getString("device","");if(device.isEmpty()){device=UUID.randomUUID().toString();prefs(this).edit().putString("device",device).commit();}

        JSONObject a; synchronized(LOCK){a=object(prefs(this).getString("acks","{}"));}

        JSONArray acknowledgments=new JSONArray();Iterator<String> keys=a.keys();while(keys.hasNext()&&acknowledgments.length()<40){String id=keys.next();acknowledgments.put(new JSONObject().put("id",id).put("status",a.getString(id)));}

        JSONObject result;

        try{result=request(new JSONObject().put("device",device).put("acks",acknowledgments).put("mode",prefs(this).getString("notificationMode","web")).put("pilot_revision",prefs(this).getInt("pilotRevision",0)).put("forward_enabled",prefs(this).getBoolean("forwardEnabled",false)).put("diagnostics",diagnostics()).put("phone_delivery",prefs(this).getString("phoneAlertDelivery","web")).put("phone_fallback",prefs(this).getBoolean("phoneAlertFallback",true)));}

        catch(Exception e){if(failures==0)ActivityTimeline.record(this,"Server connection lost");failures++;String detail=e.getMessage()!=null&&e.getMessage().startsWith("HTTP ")?e.getMessage():e.getClass().getSimpleName();prefs(this).edit().putString("lastConnectionError",detail).apply();status("Connection failed: "+detail);if(failures>=3&&!unreachable&&prefs(this).getBoolean("pairedOnce",false)){unreachable=true;prefs(this).edit().putBoolean("unreachable",true).commit();ActivityTimeline.record(this,"Endpoint unavailable; phone alert delivery awaits the incident router");}return;}

        synchronized(LOCK){JSONObject live=object(prefs(this).getString("acks","{}"));for(int i=0;i<acknowledgments.length();i++){JSONObject old=acknowledgments.getJSONObject(i);String id=old.getString("id");if(live.optString(id).equals(old.getString("status")))live.remove(id);}prefs(this).edit().putString("acks",live.toString()).commit();}

        prefs(this).edit().putBoolean("whatsappReady",result.optBoolean("whatsapp_ready",false)).putBoolean("channelSynced",true)
            .putBoolean("phoneAlertSynced", result.has("notification_history") && result.optString("phone_delivery").equals(prefs(this).getString("phoneAlertDelivery","web")) && result.optBoolean("phone_fallback") == prefs(this).getBoolean("phoneAlertFallback",true))
            .putString("phoneNotificationHistory", result.optJSONArray("notification_history")==null?prefs(this).getString("phoneNotificationHistory","[]"):result.optJSONArray("notification_history").toString()).apply();
        JSONObject control=result.optJSONObject("phone_control");
        if(control!=null){synchronized(LOCK){
            int revision=control.optInt("revision",0);String mode=control.optString("mode","");
            if(revision>prefs(this).getInt("pilotRevision",0)&&(mode.equals("web")||mode.equals("whatsapp")||mode.equals("sms"))){
                boolean forward=control.optBoolean("forward_enabled",false);
                boolean permitted=checkSelfPermission(android.Manifest.permission.SEND_SMS)==android.content.pm.PackageManager.PERMISSION_GRANTED&&checkSelfPermission(android.Manifest.permission.RECEIVE_SMS)==android.content.pm.PackageManager.PERMISSION_GRANTED;
                boolean smsAllowed=!mode.equals("sms")||checkSelfPermission(android.Manifest.permission.SEND_SMS)==android.content.pm.PackageManager.PERMISSION_GRANTED;
                if((!forward||permitted)&&smsAllowed){
                    prefs(this).edit().putString("notificationMode",mode).putBoolean("forwardEnabled",forward).putInt("pilotRevision",revision).putString("pilotStatus","Settings received from Orbit").commit();
                }else prefs(this).edit().putString("pilotStatus","Orbit change pending: grant SMS permissions in Android settings").commit();
            }
        }}
        if(failures>0)ActivityTimeline.record(this,"Server connection recovered");
        failures=0;prefs(this).edit().remove("lastConnectionError").putBoolean("pairedOnce",true).putLong("lastServerAt",System.currentTimeMillis()).putString("deliveryRecent",result.optJSONArray("delivery_recent")==null?"[]":result.optJSONArray("delivery_recent").toString()).commit();

        if(unreachable){unreachable=false;prefs(this).edit().putBoolean("unreachable",false).commit();ActivityTimeline.record(this,"Endpoint connection recovered");}

        JSONObject health=result.optJSONObject("health");boolean old=health==null||System.currentTimeMillis()/1000.0-health.optDouble("at",0)>60;

        if(health!=null)prefs(this).edit().putLong("healthAt",(long)(health.optDouble("at",0)*1000)).putString("healthIssues",health.optJSONArray("issues")==null?"[]":health.optJSONArray("issues").toString()).apply();

        staleSamples=old?staleSamples+1:0;

        if(old&&staleSamples>=3&&!stale){stale=true;prefs(this).edit().putBoolean("stale",true).commit();ActivityTimeline.record(this,"Phone health monitor report is stale");}else if(!old&&stale){stale=false;prefs(this).edit().putBoolean("stale",false).commit();ActivityTimeline.record(this,"Phone health monitor report recovered");}

        JSONArray jobs=result.optJSONArray("jobs");if(jobs!=null)for(int i=0;i<jobs.length();i++){JSONObject j=jobs.getJSONObject(i);if(j.optDouble("expires")>System.currentTimeMillis()/1000.0)sendSms(j.getString("id"),j.getString("body"),j.optBoolean("phone_alert",false));}

        PhoneWidget.updateAll(this);
        status("Connected. Phone alerts: "+("sms".equals(prefs(this).getString("phoneAlertDelivery","web"))?"SMS":"Orbit")+". Last check "+new java.text.SimpleDateFormat("HH:mm:ss",Locale.US).format(new Date()));

    }

    void sendSms(String id,String text){sendSms(id,text,false);}
    void sendSms(String id,String text,boolean phoneAlert){
        synchronized(LOCK){

        if(!prefs(this).getBoolean("enabled",false)||!(phoneAlert || prefs(this).getString("notificationMode","web").equals("sms"))){prefs(this).edit().putLong("lastBlockedSmsAt",System.currentTimeMillis()).putString("lastBlockedSmsReason","Alert SMS blocked by notification choice or paused monitoring").commit();if(!id.startsWith("local-"))ack(this,id,"failed");return;}
        if(id.length()>65||text.length()>300)return;

        // All broker summaries are English. Bound each SMS to a short single-part summary.

        if(text.length()>140)text=text.substring(0,137)+"...";

        synchronized(LOCK){JSONObject seen=object(prefs(this).getString("seen","{}"));if(seen.has(id))return;

            long now=System.currentTimeMillis(),window=prefs(this).getLong("smsWindow",0);int count=prefs(this).getInt("smsCount",0);if(now-window>60000){window=now;count=0;}

            try{seen.put(id,now);while(seen.length()>256){String oldest=null;long min=Long.MAX_VALUE;Iterator<String> it=seen.keys();while(it.hasNext()){String k=it.next();long v=seen.optLong(k);if(v<min){min=v;oldest=k;}}if(oldest==null)break;seen.remove(oldest);}}catch(Exception ignored){}

            // Record before sending: a crash must not cause a repeated SMS.

            if(!prefs(this).edit().putString("seen",seen.toString()).putLong("smsWindow",window).putInt("smsCount",count+1).commit()){ack(this,id,"failed");return;}

            if(count>=6){ack(this,id,"failed");return;}

        }

        Intent sent=new Intent(this,SmsResult.class).setAction("sms.sent."+id).putExtra("id",id).putExtra("phase","sent");

        Intent delivered=new Intent(this,SmsResult.class).setAction("sms.delivered."+id).putExtra("id",id).putExtra("phase","delivered");

        int flags=PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE;

        try{SmsManager.getDefault().sendTextMessage(DEST,null,text,PendingIntent.getBroadcast(this,id.hashCode(),sent,flags),PendingIntent.getBroadcast(this,id.hashCode(),delivered,flags));}

        catch(Exception e){ack(this,id,"failed");status("Alert SMS failed. Delivery follows your phone alert settings.");}

        }
    }

}

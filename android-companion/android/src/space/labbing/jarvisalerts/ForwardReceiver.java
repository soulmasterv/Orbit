package space.labbing.jarvisalerts;

import android.app.*;

import android.content.*;

import android.provider.Telephony;

import android.telephony.*;

import java.util.*;

import java.security.MessageDigest;

import java.nio.charset.StandardCharsets;

import org.json.*;

public class ForwardReceiver extends BroadcastReceiver {

    public void onReceive(Context context,Intent intent){


        if(!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())||!AlertService.prefs(context).getBoolean("forwardEnabled",false))return;

        SmsMessage[] messages=Telephony.Sms.Intents.getMessagesFromIntent(intent);if(messages==null||messages.length==0)return;

        String sender=messages[0].getOriginatingAddress();StringBuilder body=new StringBuilder();

        for(SmsMessage m:messages){if(!Objects.equals(sender,m.getOriginatingAddress()))return;body.append(m.getMessageBody()==null?"":m.getMessageBody());}

        if(!SmsPolicy.forward(sender,body.toString()))return;

        final PendingResult pending=goAsync();final Context c=context.getApplicationContext();final String from=sender==null?"Unknown":sender;final String text=body.toString();final long at=messages[0].getTimestampMillis();

        new Thread(()->{try{send(c,from,text,at);}catch(Exception e){AlertService.prefs(c).edit().putString("forwardStatus","Forwarding failed; original SMS remains on Samsung.").apply();}finally{pending.finish();}},"sms-forward").start();

    }

    static void send(Context c,String from,String body,long at)throws Exception{

        SmsManager sms = ForwardControls.sms(c);
        String safeFrom = from.replaceAll("[\\p{Cntrl}]", "");
        if (safeFrom.length() > 80) safeFrom = safeFrom.substring(0, 80);
        ArrayList<String> parts = sms.divideMessage("[Forwarded SMS]\nMessage from " + safeFrom + "\n" + body);
        synchronized(AlertService.LOCK){
            String blocked = ForwardControls.reason(c, parts.size());
            if (blocked != null) {
                ActivityTimeline.record(c, blocked);
                AlertService.prefs(c).edit().putString("forwardBlockReason", blocked).commit();
                return;
            }

            String legacy=ForwardDedup.hash(from+"\n"+at+"\n"+body);

            if(AlertService.object(AlertService.prefs(c).getString("forwardSeen","{}")).has(legacy)){

                AlertService.prefs(c).edit().putInt("forwardSuppressed",AlertService.prefs(c).getInt("forwardSuppressed",0)+1).commit();return;

            }

            JSONObject json=AlertService.object(AlertService.prefs(c).getString("forwardDedupV3","{}"));Map<String,Long> records=new HashMap<>();Iterator<String> keys=json.keys();while(keys.hasNext()){String k=keys.next();records.put(k,json.optLong(k));}

            boolean allowed=ForwardDedup.claim(records,from,body,at,System.currentTimeMillis());

            JSONObject updated=new JSONObject();for(Map.Entry<String,Long> entry:records.entrySet())updated.put(entry.getKey(),entry.getValue());

            android.content.SharedPreferences.Editor edit=AlertService.prefs(c).edit().putString("forwardDedupV3",updated.toString());

            String counter=allowed?"forwardAttempts":"forwardSuppressed";edit.putInt(counter,AlertService.prefs(c).getInt(counter,0)+1);

            // Persist before the radio call. An uncertain send is never replayed.

            if(!edit.commit()||!allowed)return;

        }

        String id="local-"+UUID.randomUUID();

        synchronized(AlertService.LOCK){AlertService.prefs(c).edit().putString("lastForwardId",id).putInt("lastForwardParts",parts.size()).putLong("lastForwardAt",System.currentTimeMillis()).putString("forwardStatus","Sending; awaiting carrier result.").putString("lastForwardResult","sending").commit();}
        ForwardHistory.record(c,id,"sending",parts.size(),0);

        ArrayList<PendingIntent> sent=new ArrayList<>(),delivered=new ArrayList<>();

        for(int k=0;k<parts.size();k++)for(int phase=0;phase<2;phase++){

            Intent i=new Intent(c,SmsResult.class).setAction("forward."+id+"."+phase+"."+k).putExtra("id",id).putExtra("phase",phase==0?"sent":"delivered").putExtra("part",k).putExtra("parts",parts.size()).putExtra("forward",true);

            PendingIntent p=PendingIntent.getBroadcast(c,(id+phase+"-"+k).hashCode(),i,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);(phase==0?sent:delivered).add(p);

        }

        synchronized(AlertService.LOCK){
        String blocked = ForwardControls.reason(c, parts.size());
        if (blocked != null || !ForwardControls.reserve(c, parts.size())) {
            ForwardHistory.record(c,id,"cancelled",parts.size(),0);
            AlertService.prefs(c).edit().putString("lastForwardResult","cancelled").commit();
            return;
        }
        ActivityTimeline.record(c, "Forward submitted to Android · " + parts.size() + " SMS part(s)");
        try{if(parts.size()==1)sms.sendTextMessage(AlertService.DEST,null,parts.get(0),sent.get(0),delivered.get(0));else sms.sendMultipartTextMessage(AlertService.DEST,null,parts,sent,delivered);}

        catch(Exception e){ForwardHistory.record(c,id,"failed",parts.size(),0);AlertService.prefs(c).edit().putString("lastForwardResult","failed").commit();AlertService.ack(c,id,"failed");AlertService.prefs(c).edit().putString("forwardStatus","Forward failed; web fallback will report the failure when Ubuntu is reachable.").apply();}

        }
    }

}

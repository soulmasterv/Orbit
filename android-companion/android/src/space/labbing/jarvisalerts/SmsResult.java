package space.labbing.jarvisalerts;

import android.app.Activity;

import android.content.*;

import java.util.Arrays;

public class SmsResult extends BroadcastReceiver {

    public void onReceive(Context c,Intent i){

        String id=i.getStringExtra("id"),phase=i.getStringExtra("phase");if(id==null||phase==null)return;

        int n=i.getIntExtra("parts",1),part=i.getIntExtra("part",0);if(n<1||n>255||part<0||part>=n)return;

        synchronized(AlertService.LOCK){

            String key="parts-"+id+"-"+phase;String saved=AlertService.prefs(c).getString(key,"");char[] state;

            if(saved.length()!=n){state=new char[n];Arrays.fill(state,'?');}else state=saved.toCharArray();

            state[part]=getResultCode()==Activity.RESULT_OK?'1':'0';String all=new String(state);AlertService.prefs(c).edit().putString(key,all).apply();

            String status=all.indexOf('0')>=0?"failed":all.indexOf('?')>=0?null:"delivered".equals(phase)?"delivered":"submitted";

            if(i.getBooleanExtra("forward",false)) {
                String displayStatus = status == null ? "sending" : status;
                ForwardHistory.record(c,id,displayStatus,n,getResultCode()==Activity.RESULT_OK?0:getResultCode());
                if(id.equals(AlertService.prefs(c).getString("lastForwardId","")) && status != null) {
                    String prior = AlertService.prefs(c).getString("lastForwardResult", "");
                    if (!"delivered".equals(prior) && !("failed".equals(prior) && "submitted".equals(status)))
                        AlertService.prefs(c).edit().putString("lastForwardResult",status).commit();
                }
            }
            if(status!=null){if(!i.getBooleanExtra("forward",false))AlertService.ack(c,id,status);if(i.getBooleanExtra("forward",false)&&id.equals(AlertService.prefs(c).getString("lastForwardId","")))AlertService.prefs(c).edit().putString("forwardStatus","Forward SMS: "+status+".").apply();}

        }

    }

}

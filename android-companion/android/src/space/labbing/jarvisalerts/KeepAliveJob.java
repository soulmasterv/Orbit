package space.labbing.jarvisalerts;
import android.app.job.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.Build;
import android.Manifest;
public class KeepAliveJob extends JobService {
    static final int ID=24026;
    static void schedule(Context c){
        if(!AlertService.prefs(c).getBoolean("enabled",false))return;
        JobScheduler scheduler=(JobScheduler)c.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if(scheduler.getPendingJob(ID)!=null)return;
        scheduler.schedule(new JobInfo.Builder(ID,new ComponentName(c,KeepAliveJob.class)).setPeriodic(15*60*1000L).setPersisted(true).build());
    }
    static void cancel(Context c){((JobScheduler)c.getSystemService(Context.JOB_SCHEDULER_SERVICE)).cancel(ID);}
    public boolean onStartJob(JobParameters p){
        if(!AlertService.prefs(this).getBoolean("enabled",false)){cancel(this);return false;}
        if(AlertService.prefs(this).getString("key","").isEmpty()||(AlertService.prefs(this).getString("notificationMode","web").equals("sms")&&checkSelfPermission(Manifest.permission.SEND_SMS)!=PackageManager.PERMISSION_GRANTED))return false;
        try{Intent i=new Intent(this,AlertService.class);if(Build.VERSION.SDK_INT>=26)startForegroundService(i);else startService(i);}catch(Exception e){AlertService.prefs(this).edit().putString("status","Background restart restricted; reopen JARVIS.").apply();}
        return false;
    }
    public boolean onStopJob(JobParameters p){return true;}
}

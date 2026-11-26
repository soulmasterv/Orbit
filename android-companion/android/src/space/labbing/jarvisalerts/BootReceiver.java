package space.labbing.jarvisalerts;

import android.content.*;

import android.os.Build;

public class BootReceiver extends BroadcastReceiver {

    public void onReceive(Context c,Intent i){if((!Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())&&!Intent.ACTION_MY_PACKAGE_REPLACED.equals(i.getAction()))||!AlertService.prefs(c).getBoolean("enabled",false))return;KeepAliveJob.schedule(c);Intent service=new Intent(c,AlertService.class);if(Build.VERSION.SDK_INT>=26)c.startForegroundService(service);else c.startService(service);}

}

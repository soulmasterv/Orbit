package space.labbing.jarvisalerts;
import android.bluetooth.BluetoothAdapter;
import android.content.*;
public class BluetoothEnableReceiver extends BroadcastReceiver {
 public void onReceive(Context context,Intent intent){
  if(!"space.labbing.jarvisalerts.ENABLE_BLUETOOTH".equals(intent.getAction())){setResultCode(1);setResultData("unsupported_action");return;}
  // Manifest requires DUMP: this is for authorized ADB/system callers, not other apps.
  try{
   BluetoothAdapter adapter=BluetoothAdapter.getDefaultAdapter();
   String result=adapter==null?"unavailable":adapter.isEnabled()?"already_on":adapter.enable()?"enable_requested":"enable_rejected";
   setResultCode(result.equals("already_on")||result.equals("enable_requested")?0:1);setResultData(result);
  }catch(Exception e){setResultCode(1);setResultData("enable_unavailable");}
 }
}

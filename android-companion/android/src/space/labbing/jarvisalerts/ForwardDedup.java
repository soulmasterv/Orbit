package space.labbing.jarvisalerts;
import java.util.*;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;

/** Private hashes only. Exact event identity plus a bounded content repeat window. */
public class ForwardDedup {
    public static final long REPEAT_WINDOW_MS=60000;
    public static String canonicalSender(String sender){
        String s=sender==null?"Unknown":sender.trim();
        return s.matches("[+0-9 ()-]+")?SmsPolicy.normalize(s):s.toLowerCase(Locale.ROOT);
    }
    public static String hash(String value)throws Exception{
        StringBuilder out=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)))out.append(String.format(Locale.US,"%02x",b));return out.toString();
    }
    /** Caller must persist the mutated map under its lock before sending. */
    public static boolean claim(Map<String,Long> records,String sender,String body,long smsAt,long now)throws Exception{
        String from=canonicalSender(sender),event="e:"+hash(from+"\n"+smsAt+"\n"+body),content="c:"+hash(from+"\n"+body);
        if(records.containsKey(event))return false;
        Long previous=records.get(content);
        boolean repeated=previous!=null&&now>=previous&&now-previous<REPEAT_WINDOW_MS;
        // Keep the alternate event identity even when it is suppressed, so a
        // delayed repeat of that radio event cannot be sent after the window.
        records.put(event,now);
        if(!repeated)records.put(content,now);
        while(records.size()>512){String oldest=null;long at=Long.MAX_VALUE;for(Map.Entry<String,Long> e:records.entrySet())if(e.getValue()<at){at=e.getValue();oldest=e.getKey();}if(oldest==null)break;records.remove(oldest);}
        return !repeated;
    }
}

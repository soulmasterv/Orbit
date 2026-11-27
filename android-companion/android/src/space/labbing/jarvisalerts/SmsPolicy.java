package space.labbing.jarvisalerts;
public class SmsPolicy {
    public static String normalize(String s){String n=s==null?"":s.replaceAll("[^0-9]","");if(n.startsWith("00"))n=n.substring(2);if(n.startsWith("20")&&n.length()==12)n="0"+n.substring(2);return n;}
    public static boolean forward(String sender,String body){String n=normalize(sender);return body!=null&&!body.isEmpty()&&!n.equals("01011288486")&&!body.startsWith("[JARVIS SMS]")&&!body.startsWith("[Forwarded SMS]");}
}

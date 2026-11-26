package space.labbing.jarvisalerts;
public final class PolicyTests {
    static void check(boolean value, String name) { if (!value) throw new AssertionError(name); }
    public static void main(String[] args) {
        check(ForwardPolicy.blockReason(true,100,0,0,false,false,false,true,0,900,4)==null,"unlimited quota");
        check(ForwardPolicy.blockReason(true,100,0,0,false,true,false,true,5,3,2)==null,"exact remaining quota");
        check(ForwardPolicy.blockReason(true,100,0,0,false,true,false,true,5,3,3)!=null,"multipart over quota");
        check(ForwardPolicy.blockReason(true,100,0,100,false,true,false,true,0,0,1)!=null,"expiry boundary");
        check(ForwardPolicy.blockReason(true,100,101,0,false,true,false,true,0,0,1)!=null,"temporary pause");
        check(ForwardPolicy.blockReason(true,100,0,0,true,false,false,true,0,0,1)!=null,"unknown roaming fails closed");
        check(ForwardPolicy.blockReason(true,100,0,0,true,true,true,true,0,0,1)!=null,"roaming blocked");
        check(ForwardPolicy.blockReason(true,100,0,0,false,true,true,true,0,0,1)==null,"roaming explicitly allowed");
        check(ForwardPolicy.blockReason(true,100,0,0,false,true,false,false,0,0,1)!=null,"missing SIM");
        check(ForwardPolicy.blockReason(false,100,0,0,false,true,false,true,0,0,1)!=null,"forwarding off");
        System.out.println("10 forwarding policy checks passed");
    }
}

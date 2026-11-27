package space.labbing.jarvisalerts;

/** Pure forwarding decisions shared by the UI, receiver and tests. */
final class ForwardPolicy {
    static String blockReason(boolean enabled, long now, long pauseUntil, long sessionUntil,
                              boolean roamingBlocked, boolean roamingKnown, boolean roaming,
                              boolean simReady, int limit, int used, int parts) {
        if (!enabled) return "Forwarding is off";
        if (pauseUntil > now) return "Forwarding is paused";
        if (sessionUntil > 0 && sessionUntil <= now) return "Forwarding session expired";
        if (!simReady) return "Selected SIM is unavailable";
        if (roamingBlocked && !roamingKnown) return "Roaming status could not be checked";
        if (roamingBlocked && roaming) return "Paused while roaming";
        if (limit > 0 && parts > Math.max(0, limit - used)) return "Daily SMS part limit reached";
        return null;
    }
}

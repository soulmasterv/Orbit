package space.labbing.jarvisalerts;

import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

public class ForwardTile extends TileService {
    @Override public void onStartListening() { update(); }
    @Override public void onClick() {
        if (isLocked()) unlockAndRun(this::toggle); else toggle();
    }
    private void toggle() { ForwardControls.togglePause(this); update(); }
    private void update() {
        Tile tile = getQsTile();
        if (tile == null) return;
        boolean enabled = AlertService.prefs(this).getBoolean("forwardEnabled", false);
        boolean paused = AlertService.prefs(this).getLong("forwardPauseUntil", 0) > System.currentTimeMillis();
        tile.setState(!enabled ? Tile.STATE_UNAVAILABLE : paused ? Tile.STATE_INACTIVE : Tile.STATE_ACTIVE);
        tile.setLabel(!enabled ? "Forwarding off" : paused ? "Forwarding paused" : "SMS forwarding");
        tile.updateTile();
    }
}

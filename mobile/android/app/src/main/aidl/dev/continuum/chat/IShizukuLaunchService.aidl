package dev.continuum.chat;

import android.view.Surface;

/** Narrow privileged surface used only by the Phase 1B virtual-display probe. */
interface IShizukuLaunchService {
    void destroy() = 16777114;

    /** Creates a shell-owned trusted virtual display backed by the supplied app surface. */
    String createTrustedDisplay(in Surface surface, int width, int height, int densityDpi) = 2;

    /** Releases only a display previously created by this UserService instance. */
    void releaseTrustedDisplay(int displayId) = 3;

    /** Launches and verifies the resolved activity on an already-created display. */
    String launchActivity(String component, int displayId) = 1;
}

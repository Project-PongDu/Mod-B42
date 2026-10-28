package pongduvp;

import me.zed_0xff.zombie_buddy.Patch;

/** Game thread, once per Viewpoint frame, after the camera is placed: read the Lua queues, build the frame's items. */
@Patch(className = "viewpoint.light.Torches", methodName = "snapshot")
public class PatchCapture {
    @Patch.OnExit
    public static void exit(@Patch.Argument(0) Object frame) { Fx3D.capture(frame); }
}

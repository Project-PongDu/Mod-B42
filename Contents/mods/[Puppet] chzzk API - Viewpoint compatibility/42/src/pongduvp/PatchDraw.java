package pongduvp;

import me.zed_0xff.zombie_buddy.Patch;

/** Render thread, inside Viewpoint's 3D pass right after its weather: draw the frame's items. */
@Patch(className = "viewpoint.render.WorldRenderer", methodName = "drawWeather")
public class PatchDraw {
    @Patch.OnExit
    public static void exit(@Patch.Argument(0) Object scene) { Fx3D.draw(scene); }
}

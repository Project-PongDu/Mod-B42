package pongduvp;

import me.zed_0xff.zombie_buddy.Patch;

/** Shader pack (Iris) active: Viewpoint skips drawWeather's normal path; draw after the pack's weather step instead. */
@Patch(className = "viewpoint.render.IrisGeometry", methodName = "weather")
public class PatchIris {
    @Patch.OnExit
    public static void exit(@Patch.Argument(2) Object context) { Fx3D.drawIris(context); }
}

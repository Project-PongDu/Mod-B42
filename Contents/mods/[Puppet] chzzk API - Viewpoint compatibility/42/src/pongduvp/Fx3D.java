package pongduvp;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;

import static org.lwjgl.opengl.GL33.*;

/**
 * PongDu 3D effects inside Project Viewpoint's renderer: reanimation gas clouds (dense coloured smoke,
 * PUBG smoke-grenade style) and fire-support tracers (3D direction, from the helicopter / drone / sniper).
 *
 * Data flow (same scheme as the Viewpoint add-ons that draw in its 3D pass):
 *   Lua  PongDuVP_Bridge.lua pushes entries into the globals PongDuVP_GasQueue / PongDuVP_TracerQueue.
 *   capture(frame)  game thread, exit of viewpoint.light.Torches.snapshot: drains the queues, then turns the
 *                   live clouds and tracers into this frame's billboard list in Viewpoint's render space
 *                   (camera relative: x' = -(x - camX), y' = metres up - camZ * LEVEL, z' = -(y - camY)).
 *   draw(scene)     render thread, exit of viewpoint.render.WorldRenderer.drawWeather: draws that list into
 *                   Viewpoint's target, depth-tested against the scene, no depth writes.
 * Viewpoint has no public Java API; every member is looked up by reflection once and a failure switches this
 * class off with one log line (the game keeps running, the Lua side just sees no PongDuVP_JavaFrame updates).
 *
 * Times are System.currentTimeMillis(), the same clock as Lua's getTimestampMs(), so clouds created while
 * the isometric view was on (capture does not run then) still age correctly.
 */
public final class Fx3D {
    private static final String TAG = "[PongDu][VPJ] ";
    private static final float LEVEL = 2.4494896f;           // metres per floor in Viewpoint's render space

    // ── gas ────────────────────────────────────────────────────────────────
    private static final float PUFF_ALPHA = 0.86f;           // one puff's peak opacity (overlap makes it solid)
    private static final long LINGER_MS = 5000;              // cloud stays this long after the effect's duration
    private static final long GROW_MS = 1100;                // a puff grows from 45% to full size in this time
    private static final float GOLDEN = 2.39996f;
    private static final int MAX_CLOUDS = 12;
    private static final float VEIL_EDGE = 3.5f;             // m inside the cloud edge until the view is fully veiled
    private static final float VEIL_MAX = 0.9f;

    // ── tracers ────────────────────────────────────────────────────────────
    private static final float TR_SPEED = 160f, TR_STREAK = 4f, TR_WIDTH = 0.07f;
    private static final long FLASH_MS = 70, HIT_MS = 90;
    private static final float FLASH_SIZE = 1.3f, HIT_SIZE = 0.8f;
    private static final int MAX_TRACERS = 256;

    private static final int M_TRACER = 0, M_FLASH = 1, M_PUFF = 2, M_VEIL = 3;

    private static final class Cloud {
        double x, y;
        float baseU, r, top, cr, cg, cb;
        long t0, dur, spread, fade;
        float[] puffs;                                        // per puff: ox, oy, height/size ratio, size, delay, seed
        int count;
    }

    private record Tracer(double ox, double oy, double ou, double dx, double dy, double du, double dist,
                          long t0, float alpha, boolean flash) {}

    private record Item(int mode, float ax, float ay, float az, float bx, float by, float bz,
                        float size, float r, float g, float b, float a, float seed, float dist) {}

    private record Snap(List<Item> puffs, List<Item> glows, float[] veil, float time, float light) {}

    private static final List<Cloud> clouds = new ArrayList<>();
    private static final List<Tracer> tracers = new ArrayList<>();
    private static final Map<Object, Snap> snapshots = Collections.synchronizedMap(new WeakHashMap<>());
    private static volatile boolean failed;
    private static boolean seenGas, seenTracer, drawn;
    private static long frames;
    private static final long START = System.currentTimeMillis();
    private static int program, vao;
    private static final float[] m16 = new float[16];

    // ── reflection ─────────────────────────────────────────────────────────
    private static final Map<String, Field> fields = new ConcurrentHashMap<>();
    private static final Map<String, Method> methods = new ConcurrentHashMap<>();

    private static Field field(Class<?> c, String name) throws Exception {
        String key = c.getName() + "/" + name;
        Field f = fields.get(key);
        if (f != null) return f;
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            try { f = k.getDeclaredField(name); f.setAccessible(true); fields.put(key, f); return f; }
            catch (NoSuchFieldException ignored) { }
        }
        throw new NoSuchFieldException(key);
    }

    private static Object get(Object o, String n) throws Exception { return field(o.getClass(), n).get(o); }
    private static float num(Object o, String n) throws Exception { return ((Number) get(o, n)).floatValue(); }

    private static Method method(Class<?> c, String n, Class<?>... p) throws Exception {
        String key = c.getName() + "/" + n + Arrays.toString(p);
        Method m = methods.get(key);
        if (m == null) { m = c.getMethod(n, p); methods.put(key, m); }
        return m;
    }

    private static final class API {
        static final Class<?> TABLE, RENDERER, VIEW, CLIMATE;
        static final Field ENV;
        static {
            try {
                TABLE = Class.forName("se.krka.kahlua.vm.KahluaTable");
                ENV = Class.forName("zombie.Lua.LuaManager").getField("env");
                RENDERER = Class.forName("viewpoint.render.WorldRenderer");
                VIEW = Class.forName("viewpoint.core.View");
                CLIMATE = Class.forName("zombie.iso.weather.ClimateManager");
                method(TABLE, "rawget", Object.class);
                method(TABLE, "rawget", int.class);
                method(TABLE, "rawset", Object.class, Object.class);
                method(TABLE, "len");
                method(TABLE, "wipe");
                method(CLIMATE, "getInstance");
                method(CLIMATE, "getAmbient");
                field(Class.forName("viewpoint.core.Frame"), "camX");
                field(VIEW, "enabled");
                field(RENDERER, "frame"); field(RENDERER, "irisDrawn"); method(RENDERER, "bindTarget");
                Class<?> context = Class.forName("viewpoint.render.FrameContext");
                field(context, "viewProjection"); field(context, "view");
                field(context, "eyeX"); field(context, "eyeY"); field(context, "eyeZ");
            } catch (Exception e) { throw new ExceptionInInitializerError(e); }
        }
    }

    public static void validate() {
        try {
            if (API.TABLE == null) throw new IllegalStateException("no KahluaTable");
            System.out.println(TAG + Main.VERSION + " loaded: viewpoint 3D gas + tracers");
        } catch (Throwable e) { disable("init", e); }
    }

    private static void disable(String where, Throwable e) {
        if (!failed) { System.out.println(TAG + "disabled (" + where + "): " + e); e.printStackTrace(); }
        failed = true;
        snapshots.clear();
        clouds.clear();
        tracers.clear();
    }

    // ── Lua queues ─────────────────────────────────────────────────────────
    private static double d(Object table, String key, double def) throws Exception {
        Object v = method(API.TABLE, "rawget", Object.class).invoke(table, key);
        return v instanceof Number n ? n.doubleValue() : def;
    }

    private static Object queue(Object env, String name) throws Exception {
        return method(API.TABLE, "rawget", Object.class).invoke(env, name);
    }

    private static void drain(long now) throws Exception {
        Object env = API.ENV.get(null);
        if (env == null) return;
        Method byIndex = method(API.TABLE, "rawget", int.class);
        Method len = method(API.TABLE, "len");
        Method wipe = method(API.TABLE, "wipe");

        Object gq = queue(env, "PongDuVP_GasQueue");
        if (gq != null) {
            int n = ((Number) len.invoke(gq)).intValue();
            for (int i = 1; i <= n; i++) {
                Object e = byIndex.invoke(gq, i);
                if (e == null) continue;
                try {
                    Cloud c = makeCloud(d(e, "x", 0), d(e, "y", 0), d(e, "z", 0), (float) d(e, "r", 0),
                        (long) d(e, "t0", now), (long) d(e, "dur", 0), (long) d(e, "spread", 0), (long) d(e, "fade", 0),
                        (float) d(e, "cr", 0.6), (float) d(e, "cg", 0.6), (float) d(e, "cb", 0.6));
                    if (c == null) continue;
                    if (now - c.t0 >= c.dur + LINGER_MS) continue;    // already over (queued long ago)
                    if (clouds.size() >= MAX_CLOUDS) clouds.remove(0);
                    clouds.add(c);
                    System.out.println(TAG + String.format("gas cloud at %.0f,%.0f r=%.0f puffs=%d top=%.1fm age=%dms",
                        c.x, c.y, c.r, c.count, c.top, now - c.t0));
                } catch (RuntimeException ex) {
                    System.out.println(TAG + "bad gas entry skipped: " + ex);
                }
            }
            if (n > 0) wipe.invoke(gq);
        }

        Object tq = queue(env, "PongDuVP_TracerQueue");
        if (tq != null) {
            int n = ((Number) len.invoke(tq)).intValue();
            for (int i = 1; i <= n; i++) {
                Object e = byIndex.invoke(tq, i);
                if (e == null) continue;
                double ox = d(e, "ox", 0), oy = d(e, "oy", 0), ou = d(e, "ou", 0);
                double dx = d(e, "tx", 0) - ox, dy = d(e, "ty", 0) - oy, du = d(e, "tu", 0) - ou;
                double dist = Math.sqrt(dx * dx + dy * dy + du * du);
                if (!(dist > 0.3) || !Double.isFinite(dist)) continue;
                Object flash = method(API.TABLE, "rawget", Object.class).invoke(e, "flash");
                if (tracers.size() >= MAX_TRACERS) tracers.remove(0);
                tracers.add(new Tracer(ox, oy, ou, dx / dist, dy / dist, du / dist, dist,
                    (long) d(e, "t0", now), (float) d(e, "a", 0.9), Boolean.TRUE.equals(flash)));
            }
            if (n > 0) wipe.invoke(tq);
        }
    }

    private static float clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

    /** Puff layout, fixed for the cloud's life: a ground layer over the whole disc and a smaller upper layer. */
    private static Cloud makeCloud(double x, double y, double z, float r, long t0, long dur, long spread, long fade,
                                   float cr, float cg, float cb) {
        if (!(r > 0) || dur <= 0 || !Double.isFinite(x + y + z)) return null;
        Cloud c = new Cloud();
        c.x = x; c.y = y; c.baseU = (float) (z * LEVEL); c.r = r;
        c.t0 = t0; c.dur = dur; c.spread = Math.max(0, spread); c.fade = Math.max(0, fade);
        c.cr = cr; c.cg = cg; c.cb = cb;
        Random rnd = new Random(Double.doubleToLongBits(x * 7919.0 + y) ^ t0);
        float s = clamp(r * 0.30f, 3.5f, 10f);                 // typical puff diameter (m)
        float place = Math.max(0f, r - s * 0.45f);             // puff centres stay inside so the edge is ~r
        int n1 = (int) clamp(Math.round(Math.PI * place * place / (0.55f * s * s)), 10, 200);
        int n2 = Math.max(4, Math.round(n1 * 0.45f));
        c.count = n1 + n2;
        c.puffs = new float[c.count * 6];
        int o = 0;
        for (int i = 0; i < n1; i++, o += 6) {
            float rr = place * (float) Math.sqrt((i + 0.5f) / n1);
            float ang = i * GOLDEN + (rnd.nextFloat() - 0.5f) * 0.4f;
            c.puffs[o] = (float) Math.cos(ang) * rr;
            c.puffs[o + 1] = (float) Math.sin(ang) * rr;
            // centre at ~0.32 x size so the puff's lower edge reaches the ground; the shader fades the last
            // 1.4 m above the floor (b.y) so the ground does not cut the billboard in a hard straight line.
            c.puffs[o + 2] = 0.32f + rnd.nextFloat() * 0.06f;
            c.puffs[o + 3] = s * (0.85f + rnd.nextFloat() * 0.40f);
            c.puffs[o + 4] = place > 0 ? c.spread * (rr / place) : 0f;   // centre first, edge last
            c.puffs[o + 5] = rnd.nextFloat();
        }
        float upper = place * 0.72f;
        for (int i = 0; i < n2; i++, o += 6) {
            float rr = upper * (float) Math.sqrt((i + 0.5f) / n2);
            float ang = i * GOLDEN + 1.3f + (rnd.nextFloat() - 0.5f) * 0.4f;
            c.puffs[o] = (float) Math.cos(ang) * rr;
            c.puffs[o + 1] = (float) Math.sin(ang) * rr;
            c.puffs[o + 3] = s * (0.80f + rnd.nextFloat() * 0.35f);
            c.puffs[o + 2] = s * (0.80f + rnd.nextFloat() * 0.20f) / c.puffs[o + 3];
            c.puffs[o + 4] = (place > 0 ? c.spread * (rr / place) : 0f) + 250f;
            c.puffs[o + 5] = rnd.nextFloat();
        }
        c.top = s * 1.35f;
        return c;
    }

    private static float ambientLight() {
        try {
            Object cm = method(API.CLIMATE, "getInstance").invoke(null);
            float a = ((Number) method(API.CLIMATE, "getAmbient").invoke(cm)).floatValue();
            return 0.18f + 0.82f * clamp(a, 0f, 1f);
        } catch (Throwable t) {
            return 1f;
        }
    }

    // ── game thread ────────────────────────────────────────────────────────
    public static void capture(Object frame) {
        if (failed || frame == null) return;
        try {
            Object scene = get(frame, "scene");
            long now = System.currentTimeMillis();
            Object env = API.ENV.get(null);
            if (env != null) {
                method(API.TABLE, "rawset", Object.class, Object.class).invoke(env, "PongDuVP_JavaFrame", (double) (++frames));
            }
            drain(now);
            clouds.removeIf(c -> now - c.t0 >= c.dur + LINGER_MS);
            tracers.removeIf(t -> (now - t.t0) / 1000.0 * TR_SPEED > t.dist + TR_SPEED * HIT_MS / 1000.0 + TR_STREAK);
            if (!field(API.VIEW, "enabled").getBoolean(null)) { snapshots.remove(scene); return; }
            if (clouds.isEmpty() && tracers.isEmpty()) { snapshots.remove(scene); return; }

            float cx = num(frame, "camX"), cy = num(frame, "camY"), cz = num(frame, "camZ");
            float camU = cz * LEVEL;
            float light = ambientLight();
            List<Item> puffs = new ArrayList<>();
            List<Item> glows = new ArrayList<>();
            float[] veil = new float[4];

            for (Cloud c : clouds) {
                long age = Math.max(0, now - c.t0);
                long total = c.dur + LINGER_MS;
                float lifeFrac = clamp(age / (float) total, 0f, 1f);
                float out = clamp((c.t0 + total - now) / (float) (c.fade + LINGER_MS), 0f, 1f);
                out = out * out * (3f - 2f * out);
                float spreadOut = 1f + 0.10f * lifeFrac;
                float rise = 0.6f * lifeFrac;
                for (int i = 0, o = 0; i < c.count; i++, o += 6) {
                    float k = clamp((age - c.puffs[o + 4]) / (float) GROW_MS, 0f, 1f);
                    if (k <= 0f) continue;
                    float ease = 1f - (1f - k) * (1f - k) * (1f - k);
                    float a = PUFF_ALPHA * ease * out;
                    if (a < 0.01f) continue;
                    float size = c.puffs[o + 3] * (0.45f + 0.55f * ease) * (1f + 0.15f * lifeFrac);
                    double wx = c.x + c.puffs[o] * spreadOut, wy = c.y + c.puffs[o + 1] * spreadOut;
                    float px = (float) -(wx - cx), py = c.baseU + size * c.puffs[o + 2] + rise - camU, pz = (float) -(wy - cy);
                    float dist = px * px + py * py + pz * pz;
                    puffs.add(new Item(M_PUFF, px, py, pz, 0, c.baseU - camU, 0, size, c.cr, c.cg, c.cb, a, c.puffs[o + 5], dist));
                }
                // camera inside the cloud: veil the whole view in its colour
                double hd = Math.hypot(cx - c.x, cy - c.y);
                float edge = c.r * spreadOut;
                float grown = clamp(age / (float) (c.spread + GROW_MS), 0f, 1f);
                if (hd < edge && camU - c.baseU < c.top) {
                    float v = clamp((float) (edge - hd) / VEIL_EDGE, 0f, 1f) * grown * out * VEIL_MAX;
                    if (v > veil[3]) { veil[0] = c.cr; veil[1] = c.cg; veil[2] = c.cb; veil[3] = v; }
                }
            }
            puffs.sort(Comparator.comparingDouble(it -> -it.dist));    // far to near (alpha blending)

            for (Tracer t : tracers) {
                double nose = Math.max(0, now - t.t0) / 1000.0 * TR_SPEED;
                double tail = Math.max(0, nose - TR_STREAK), head = Math.min(nose, t.dist);
                if (head > tail) {
                    glows.add(new Item(M_TRACER,
                        (float) -(t.ox + t.dx * tail - cx), (float) (t.ou + t.du * tail - camU), (float) -(t.oy + t.dy * tail - cy),
                        (float) -(t.ox + t.dx * head - cx), (float) (t.ou + t.du * head - camU), (float) -(t.oy + t.dy * head - cy),
                        TR_WIDTH, 1f, 0.86f, 0.5f, t.alpha, 0f, 0f));
                }
                long since = now - t.t0;
                if (t.flash && since < FLASH_MS) {
                    float k = 1f - since / (float) FLASH_MS;
                    glows.add(new Item(M_FLASH,
                        (float) -(t.ox - cx), (float) (t.ou - camU), (float) -(t.oy - cy), 0, 0, 0,
                        FLASH_SIZE * (0.6f + 0.4f * k), 1f, 0.8f, 0.4f, k * t.alpha / 0.9f, 0f, 0f));
                }
                double hitAt = t.dist / TR_SPEED * 1000.0;
                if (since >= hitAt && since < hitAt + HIT_MS) {
                    float k = 1f - (float) ((since - hitAt) / HIT_MS);
                    double ex = t.ox + t.dx * t.dist, ey = t.oy + t.dy * t.dist, eu = t.ou + t.du * t.dist;
                    glows.add(new Item(M_FLASH, (float) -(ex - cx), (float) (eu - camU), (float) -(ey - cy), 0, 0, 0,
                        HIT_SIZE, 1f, 0.75f, 0.4f, k * 0.8f * t.alpha / 0.9f, 0f, 0f));
                }
            }

            float time = (now - START) / 1000f;
            snapshots.put(scene, new Snap(List.copyOf(puffs), List.copyOf(glows), veil, time, light));
            if (!puffs.isEmpty() && !seenGas) { seenGas = true; System.out.println(TAG + "first gas frame (" + puffs.size() + " puffs)"); }
            if (!glows.isEmpty() && !seenTracer) { seenTracer = true; System.out.println(TAG + "first tracer frame (" + glows.size() + " items)"); }
        } catch (Throwable e) { disable("capture", e); }
    }

    // ── GL ─────────────────────────────────────────────────────────────────
    private static int shader(int type, String source) {
        int s = glCreateShader(type);
        glShaderSource(s, source);
        glCompileShader(s);
        if (glGetShaderi(s, GL_COMPILE_STATUS) == 0) {
            String log = glGetShaderInfoLog(s);
            glDeleteShader(s);
            throw new IllegalStateException(log);
        }
        return s;
    }

    private static final String VS = """
        #version 330 core
        uniform mat4 vp;
        uniform int mode;
        uniform vec3 a;
        uniform vec3 b;
        uniform float size;
        uniform vec3 eye;
        uniform vec3 right;
        uniform vec3 up;
        out vec2 uv;
        out float nearK;
        out float vY;
        out float floorY;
        const vec2 corners[6] = vec2[6](vec2(0,0), vec2(1,0), vec2(1,1), vec2(0,0), vec2(1,1), vec2(0,1));
        void main() {
            vec2 q = corners[gl_VertexID];
            uv = q;
            nearK = 1.0;
            vY = 0.0;
            floorY = b.y;
            if (mode == 3) { gl_Position = vec4(q * 2.0 - 1.0, 0.0, 1.0); return; }
            vec3 p;
            if (mode == 0) {
                vec3 mid = (a + b) * 0.5;
                vec3 side = cross(b - a, eye - mid);
                if (dot(side, side) < 1e-8) side = up;
                side = normalize(side);
                float w = size * (1.0 + length(eye - mid) * 0.015);
                p = mix(a, b, q.x) + side * (q.y - 0.5) * w;
            } else {
                p = a + right * (q.x - 0.5) * size + up * (q.y - 0.5) * size;
                if (mode == 2) {
                    float rad = size * 0.5;
                    nearK = smoothstep(rad * 0.35, rad * 1.1, length(a - eye));
                }
            }
            vY = p.y;
            gl_Position = vp * vec4(p, 1.0);
        }
        """;

    private static final String FS = """
        #version 330 core
        uniform int mode;
        uniform vec4 tint;
        uniform float seed;
        uniform float time;
        uniform float light;
        in vec2 uv;
        in float nearK;
        in float vY;
        in float floorY;
        out vec4 color;
        float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float noise(vec2 p) {
            vec2 i = floor(p), f = fract(p);
            vec2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
                       mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
        }
        float fbm(vec2 p) {
            float v = 0.0, amp = 0.5;
            for (int k = 0; k < 4; k++) { v += amp * noise(p); p = p * 2.03 + vec2(17.0, 9.0); amp *= 0.5; }
            return v;
        }
        void main() {
            if (mode == 3) {                       // veil (premultiplied)
                color = vec4(tint.rgb * light * tint.a, tint.a);
                return;
            }
            if (mode == 2) {                       // smoke puff (premultiplied alpha)
                vec2 c = uv * 2.0 - 1.0;
                float ang = seed * 6.2831853;
                vec2 rc = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * c;
                float n = fbm(rc * 1.7 + vec2(seed * 13.0, seed * 7.0) + vec2(time * 0.04, -time * 0.03));
                float shape = 1.0 - smoothstep(0.38, 1.0, length(c) + (n - 0.5) * 0.7);
                // fade into the ground instead of a hard cut where the billboard goes below it
                float al = shape * tint.a * nearK * smoothstep(floorY, floorY + 1.4, vY);
                if (al < 0.003) discard;
                float lit = 0.58 + 0.52 * clamp(0.5 + c.y * 0.6 + (n - 0.5) * 0.7, 0.0, 1.0);
                color = vec4(tint.rgb * lit * light * al, al);
                return;
            }
            float i;                               // tracer / flash (additive)
            if (mode == 0) {
                float across = 1.0 - abs(uv.y * 2.0 - 1.0);
                i = pow(uv.x, 1.4) * pow(across, 0.8);
            } else {
                vec2 c = uv - 0.5;
                float d = length(c) * 2.0;
                float core = pow(max(1.0 - d, 0.0), 2.0);
                float flareH = exp(-abs(c.y) * 22.0) * max(1.0 - abs(c.x) * 2.0, 0.0);
                float flareV = exp(-abs(c.x) * 22.0) * max(1.0 - abs(c.y) * 2.0, 0.0) * 0.6;
                i = min(core * 1.2 + flareH + flareV, 1.5);
            }
            float al = clamp(i * tint.a, 0.0, 1.0);
            if (al < 0.004) discard;
            color = vec4(tint.rgb * (0.6 + 0.8 * i), al);
        }
        """;

    private static void initGL() {
        if (program != 0) return;
        int vs = shader(GL_VERTEX_SHADER, VS);
        int fs = shader(GL_FRAGMENT_SHADER, FS);
        int p = glCreateProgram();
        glAttachShader(p, vs);
        glAttachShader(p, fs);
        glLinkProgram(p);
        glDeleteShader(vs);
        glDeleteShader(fs);
        if (glGetProgrami(p, GL_LINK_STATUS) == 0) {
            String log = glGetProgramInfoLog(p);
            glDeleteProgram(p);
            throw new IllegalStateException(log);
        }
        program = p;
        vao = glGenVertexArrays();
    }

    private static void toggle(int cap, boolean on) { if (on) glEnable(cap); else glDisable(cap); }

    /** Normal world pass. With a shader pack Viewpoint draws through Iris and drawIris() takes over. */
    public static void draw(Object scene) {
        if (failed) return;
        try {
            if (field(API.RENDERER, "irisDrawn").getBoolean(null)) return;
        } catch (Throwable e) {
            return;
        }
        render(scene, null, true);
    }

    public static void drawIris(Object context) {
        if (failed || context == null) return;
        try {
            render(get(context, "scene"), context, false);
        } catch (Throwable e) { disable("drawIris", e); }
    }

    private static void render(Object scene, Object ctx, boolean bind) {
        Snap snap = snapshots.get(scene);
        if (snap == null || (snap.puffs.isEmpty() && snap.glows.isEmpty() && snap.veil[3] < 0.01f)) return;
        try {
            Object context = ctx != null ? ctx : field(API.RENDERER, "frame").get(null);
            if (context == null) return;
            Object vp = get(context, "viewProjection"), view = get(context, "view");
            float ex = num(context, "eyeX"), ey = num(context, "eyeY"), ez = num(context, "eyeZ");
            method(view.getClass(), "get", float[].class).invoke(view, (Object) m16);
            float rx = m16[0], ry = m16[4], rz = m16[8];            // view matrix rows = camera axes
            float ux = m16[1], uy = m16[5], uz = m16[9];

            int oldProgram = glGetInteger(GL_CURRENT_PROGRAM), oldVao = glGetInteger(GL_VERTEX_ARRAY_BINDING);
            int fbo = glGetInteger(GL_DRAW_FRAMEBUFFER_BINDING), readFbo = glGetInteger(GL_READ_FRAMEBUFFER_BINDING);
            int[] viewport = new int[4];
            glGetIntegerv(GL_VIEWPORT, viewport);
            boolean blend = glIsEnabled(GL_BLEND), depth = glIsEnabled(GL_DEPTH_TEST), cull = glIsEnabled(GL_CULL_FACE),
                scissor = glIsEnabled(GL_SCISSOR_TEST), mask = glGetBoolean(GL_DEPTH_WRITEMASK);
            int df = glGetInteger(GL_DEPTH_FUNC), sr = glGetInteger(GL_BLEND_SRC_RGB), dr = glGetInteger(GL_BLEND_DST_RGB),
                sa = glGetInteger(GL_BLEND_SRC_ALPHA), da = glGetInteger(GL_BLEND_DST_ALPHA),
                er = glGetInteger(GL_BLEND_EQUATION_RGB), ea = glGetInteger(GL_BLEND_EQUATION_ALPHA);
            try {
                initGL();
                if (bind) method(API.RENDERER, "bindTarget").invoke(null);
                glUseProgram(program);
                glBindVertexArray(vao);
                glEnable(GL_BLEND);
                glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
                glEnable(GL_DEPTH_TEST);
                glDepthFunc(GL_LEQUAL);
                glDepthMask(false);
                glDisable(GL_CULL_FACE);
                glDisable(GL_SCISSOR_TEST);

                float[] vpm = (float[]) method(vp.getClass(), "get", float[].class).invoke(vp, (Object) new float[16]);
                glUniformMatrix4fv(glGetUniformLocation(program, "vp"), false, vpm);
                glUniform3f(glGetUniformLocation(program, "eye"), ex, ey, ez);
                glUniform3f(glGetUniformLocation(program, "right"), rx, ry, rz);
                glUniform3f(glGetUniformLocation(program, "up"), ux, uy, uz);
                glUniform1f(glGetUniformLocation(program, "time"), snap.time);
                glUniform1f(glGetUniformLocation(program, "light"), snap.light);
                int uMode = glGetUniformLocation(program, "mode"), uA = glGetUniformLocation(program, "a"),
                    uB = glGetUniformLocation(program, "b"), uSize = glGetUniformLocation(program, "size"),
                    uTint = glGetUniformLocation(program, "tint"), uSeed = glGetUniformLocation(program, "seed");

                // smoke: premultiplied alpha, far to near; the target's alpha is left alone
                glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
                for (Item it : snap.puffs) drawItem(it, uMode, uA, uB, uSize, uTint, uSeed);

                // tracers and flashes: additive (they glow)
                glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE, GL_ZERO, GL_ONE);
                for (Item it : snap.glows) drawItem(it, uMode, uA, uB, uSize, uTint, uSeed);

                // camera inside a cloud: full-screen veil
                if (snap.veil[3] >= 0.01f) {
                    glDisable(GL_DEPTH_TEST);
                    glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
                    glUniform1i(uMode, M_VEIL);
                    glUniform4f(uTint, snap.veil[0], snap.veil[1], snap.veil[2], snap.veil[3]);
                    glDrawArrays(GL_TRIANGLES, 0, 6);
                }
                if (!drawn) { drawn = true; System.out.println(TAG + "first 3D draw completed (iris=" + !bind + ")"); }
            } finally {
                glUseProgram(oldProgram);
                glBindVertexArray(oldVao);
                glBlendEquationSeparate(er, ea);
                glBlendFuncSeparate(sr, dr, sa, da);
                toggle(GL_BLEND, blend);
                glDepthFunc(df);
                glDepthMask(mask);
                toggle(GL_DEPTH_TEST, depth);
                toggle(GL_CULL_FACE, cull);
                toggle(GL_SCISSOR_TEST, scissor);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, readFbo);
                glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
            }
        } catch (Throwable e) { disable("render", e); }
    }

    private static void drawItem(Item it, int uMode, int uA, int uB, int uSize, int uTint, int uSeed) {
        glUniform1i(uMode, it.mode);
        glUniform3f(uA, it.ax, it.ay, it.az);
        glUniform3f(uB, it.bx, it.by, it.bz);
        glUniform1f(uSize, it.size);
        glUniform4f(uTint, it.r, it.g, it.b, it.a);
        glUniform1f(uSeed, it.seed);
        glDrawArrays(GL_TRIANGLES, 0, 6);
    }

    private Fx3D() {}
}

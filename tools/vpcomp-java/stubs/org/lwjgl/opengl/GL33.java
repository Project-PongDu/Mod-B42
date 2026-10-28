package org.lwjgl.opengl;

/**
 * Compile-only stub of LWJGL 3 GL33 (only what PongDuVP uses). Never shipped: the game's LWJGL is used
 * at runtime. Method descriptors match the Methodrefs in the compiled Viewpoint3DTracerFix /
 * Advanced Throwables jars (javap); constant values match the ints those jars pass (sipush/ldc).
 * Constants are inlined by javac, so they must be the real GL enum values.
 */
public class GL33 {
    public static final int GL_ZERO = 0;
    public static final int GL_TRIANGLES = 4;
    public static final int GL_ONE = 1;
    public static final int GL_SRC_ALPHA = 0x0302;
    public static final int GL_ONE_MINUS_SRC_ALPHA = 0x0303;
    public static final int GL_LEQUAL = 0x0203;
    public static final int GL_CULL_FACE = 0x0B44;
    public static final int GL_DEPTH_TEST = 0x0B71;
    public static final int GL_DEPTH_WRITEMASK = 0x0B72;
    public static final int GL_DEPTH_FUNC = 0x0B74;
    public static final int GL_BLEND = 0x0BE2;
    public static final int GL_VIEWPORT = 0x0BA2;
    public static final int GL_SCISSOR_TEST = 0x0C11;
    public static final int GL_FUNC_ADD = 0x8006;
    public static final int GL_BLEND_EQUATION_RGB = 0x8009;
    public static final int GL_BLEND_DST_RGB = 0x80C8;
    public static final int GL_BLEND_SRC_RGB = 0x80C9;
    public static final int GL_BLEND_DST_ALPHA = 0x80CA;
    public static final int GL_BLEND_SRC_ALPHA = 0x80CB;
    public static final int GL_VERTEX_ARRAY_BINDING = 0x85B5;
    public static final int GL_BLEND_EQUATION_ALPHA = 0x883D;
    public static final int GL_FRAGMENT_SHADER = 0x8B30;
    public static final int GL_VERTEX_SHADER = 0x8B31;
    public static final int GL_COMPILE_STATUS = 0x8B81;
    public static final int GL_LINK_STATUS = 0x8B82;
    public static final int GL_CURRENT_PROGRAM = 0x8B8D;
    public static final int GL_DRAW_FRAMEBUFFER_BINDING = 0x8CA6;
    public static final int GL_READ_FRAMEBUFFER = 0x8CA8;
    public static final int GL_DRAW_FRAMEBUFFER = 0x8CA9;
    public static final int GL_READ_FRAMEBUFFER_BINDING = 0x8CAA;

    private static UnsupportedOperationException stub() { return new UnsupportedOperationException("stub"); }

    public static void glAttachShader(int a, int b) { throw stub(); }
    public static void glBindFramebuffer(int a, int b) { throw stub(); }
    public static void glBindVertexArray(int a) { throw stub(); }
    public static void glBlendEquationSeparate(int a, int b) { throw stub(); }
    public static void glBlendFuncSeparate(int a, int b, int c, int d) { throw stub(); }
    public static void glCompileShader(int a) { throw stub(); }
    public static int glCreateProgram() { throw stub(); }
    public static int glCreateShader(int a) { throw stub(); }
    public static void glDeleteProgram(int a) { throw stub(); }
    public static void glDeleteShader(int a) { throw stub(); }
    public static void glDepthFunc(int a) { throw stub(); }
    public static void glDepthMask(boolean a) { throw stub(); }
    public static void glDisable(int a) { throw stub(); }
    public static void glDrawArrays(int a, int b, int c) { throw stub(); }
    public static void glEnable(int a) { throw stub(); }
    public static int glGenVertexArrays() { throw stub(); }
    public static boolean glGetBoolean(int a) { throw stub(); }
    public static int glGetInteger(int a) { throw stub(); }
    public static void glGetIntegerv(int a, int[] b) { throw stub(); }
    public static String glGetProgramInfoLog(int a) { throw stub(); }
    public static int glGetProgrami(int a, int b) { throw stub(); }
    public static String glGetShaderInfoLog(int a) { throw stub(); }
    public static int glGetShaderi(int a, int b) { throw stub(); }
    public static int glGetUniformLocation(int a, CharSequence b) { throw stub(); }
    public static boolean glIsEnabled(int a) { throw stub(); }
    public static void glLinkProgram(int a) { throw stub(); }
    public static void glShaderSource(int a, CharSequence b) { throw stub(); }
    public static void glUniform1f(int a, float b) { throw stub(); }
    public static void glUniform1i(int a, int b) { throw stub(); }
    public static void glUniform3f(int a, float b, float c, float d) { throw stub(); }
    public static void glUniform4f(int a, float b, float c, float d, float e) { throw stub(); }
    public static void glUniformMatrix4fv(int a, boolean b, float[] c) { throw stub(); }
    public static void glUseProgram(int a) { throw stub(); }
    public static void glViewport(int a, int b, int c, int d) { throw stub(); }
}

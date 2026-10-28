package me.zed_0xff.zombie_buddy;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Compile-only stub of ZombieBuddy's @Patch (only the members PongDuVP uses).
 * Shape checked against the compiled Viewpoint3DTracerFix PatchCapture.class (javap -v):
 * RuntimeVisibleAnnotations, elements className/methodName, nested OnExit and Argument(value).
 * The real class comes from the ZombieBuddy mod at runtime; this file is never shipped.
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Patch {
    String className();
    String methodName();

    @Retention(RetentionPolicy.RUNTIME)
    @Target(ElementType.METHOD)
    @interface OnExit {}

    @Retention(RetentionPolicy.RUNTIME)
    @Target(ElementType.PARAMETER)
    @interface Argument {
        int value();
    }
}

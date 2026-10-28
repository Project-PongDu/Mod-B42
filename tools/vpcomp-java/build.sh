#!/usr/bin/env bash
# Builds the Java part of the Viewpoint compatibility mod (t3chzzkDonationB42_ViewpointComp).
#   source : Contents/mods/[Puppet] chzzk API - Viewpoint compatibility/42/src/pongduvp/*.java
#   output : Contents/mods/[Puppet] chzzk API - Viewpoint compatibility/42/media/java/client/PongDuVP.jar
# Needs a JDK 21+ (javac, jar). Compiles against the compile-only stubs in ./stubs (LWJGL GL33 subset and
# ZombieBuddy's @Patch); the game's own LWJGL and ZombieBuddy are used at runtime, the stubs are not shipped.
# Everything else (Kahlua, Viewpoint, ClimateManager) is reached by reflection, so no game jar is needed.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
mod="$repo/Contents/mods/[Puppet] chzzk API - Viewpoint compatibility/42"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs" "$tmp/classes" "$mod/media/java/client"
javac --release 21 -d "$tmp/stubs" $(find "$here/stubs" -name '*.java')
javac --release 21 -Xlint:all -cp "$tmp/stubs" -d "$tmp/classes" "$mod/src/pongduvp/"*.java
ver="$(sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$mod/src/pongduvp/Main.java")"
printf 'Implementation-Title: PongDu Viewpoint compatibility\nImplementation-Version: %s\n' "$ver" > "$tmp/manifest.txt"
jar --create --file "$mod/media/java/client/PongDuVP.jar" --manifest "$tmp/manifest.txt" -C "$tmp/classes" .
echo "built PongDuVP.jar $ver"
jar --list --file "$mod/media/java/client/PongDuVP.jar"

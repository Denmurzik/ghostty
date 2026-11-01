// Minimal cursor trail for the long-tab lag repro (test/windows/e2e/long-tab-lag.ps1).
// Our own shader (R-M8-37). A 200 ms trail runs from the previous cursor to
// the current one and shrinks towards the current cursor as
// (iTime - iTimeCursorChange) goes from 0 to 0.2 s. With
// custom-shader-animation = true the renderer draws a frame on every vblank,
// whatever the terminal does: that is the load this scenario needs.

const float TRAIL_SECONDS = 0.2;

float segDist(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

// iCurrentCursor / iPreviousCursor: xy = top left, zw = size, y up.
vec2 cursorCenter(vec4 c) {
    return vec2(c.x + c.z * 0.5, c.y - c.w * 0.5);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 base = texture(iChannel0, fragCoord / iResolution.xy);

    float age = clamp((iTime - iTimeCursorChange) / TRAIL_SECONDS, 0.0, 1.0);
    float strength = 1.0 - age;
    if (iCursorVisible == 0 || strength <= 0.0) {
        fragColor = base;
        return;
    }

    vec2 head = cursorCenter(iCurrentCursor);
    vec2 tail = mix(cursorCenter(iPreviousCursor), head, age);
    float radius = max(iCurrentCursor.w, 1.0) * 0.4;
    float d = segDist(fragCoord, tail, head);
    float glow = (1.0 - smoothstep(0.0, radius, d)) * strength;

    fragColor = vec4(mix(base.rgb, iCurrentCursorColor.rgb, glow * 0.6), base.a);
}

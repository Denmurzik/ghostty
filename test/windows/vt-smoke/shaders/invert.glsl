// Inverts the terminal colours: #102030 becomes #EFDFCF.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = vec4(1.0 - c.rgb, c.a);
}

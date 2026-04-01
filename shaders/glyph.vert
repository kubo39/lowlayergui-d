#version 450

struct GlyphInstance {
    vec4 posRect;  // x, y, w, h (NDC)
    vec4 uvRect;   // u0, v0, u1, v1
    vec4 color;    // RGBA
};

layout(set = 0, binding = 0) readonly buffer GlyphBuffer {
    GlyphInstance glyphs[];
} glyphBuf;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;

// 6 頂点でクワッドを形成 (CCW)
const vec2 quadCorner[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main()
{
    GlyphInstance inst = glyphBuf.glyphs[gl_InstanceIndex];
    vec2 uv  = quadCorner[gl_VertexIndex];
    vec2 pos = inst.posRect.xy + uv * inst.posRect.zw;

    gl_Position = vec4(pos, 0.0, 1.0);
    fragUV      = mix(inst.uvRect.xy, inst.uvRect.zw, uv);
    fragColor   = inst.color;
}

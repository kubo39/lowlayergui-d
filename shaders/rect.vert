#version 450

struct RectInstance {
    vec4  rect;          // x, y, width, height (NDC)
    vec4  color;         // RGBA
    float cornerRadius;
    float _pad0, _pad1, _pad2;
};

layout(set = 0, binding = 0) readonly buffer RectBuffer {
    RectInstance rects[];
} rectBuf;

layout(location = 0) out vec4  fragColor;
layout(location = 1) out vec2  fragLocalPos;
layout(location = 2) out vec2  fragRectSize;
layout(location = 3) out float fragCornerRadius;

// Two triangles forming a quad (CCW winding)
const vec2 quadUV[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

void main() {
    RectInstance inst = rectBuf.rects[gl_InstanceIndex];
    vec2 uv  = quadUV[gl_VertexIndex];
    vec2 pos = inst.rect.xy + uv * inst.rect.zw;

    gl_Position      = vec4(pos, 0.0, 1.0);
    fragColor        = inst.color;
    fragLocalPos     = uv * inst.rect.zw;
    fragRectSize     = inst.rect.zw;
    fragCornerRadius = inst.cornerRadius;
}

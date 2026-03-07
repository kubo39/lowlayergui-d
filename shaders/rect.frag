#version 450

layout(location = 0) in vec4  fragColor;
layout(location = 1) in vec2  fragLocalPos;
layout(location = 2) in vec2  fragRectSize;
layout(location = 3) in float fragCornerRadius;

layout(location = 0) out vec4 outColor;

// Signed distance function for a rounded rectangle.
// p: position relative to rect center
// halfSize: half extents of the rect
// r: corner radius
float roundedBoxSDF(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    if (fragCornerRadius > 0.0) {
        vec2 halfSize = fragRectSize * 0.5;
        vec2 p        = fragLocalPos - halfSize;
        float d       = roundedBoxSDF(p, halfSize, fragCornerRadius);
        if (d > 0.0) discard;
    }
    outColor = fragColor;
}

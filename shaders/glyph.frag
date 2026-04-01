#version 450

layout(set = 0, binding = 1) uniform sampler2D glyphAtlas;

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

void main()
{
    // R チャンネルをアルファとして使用 (VK_FORMAT_R8_UNORM アトラス)
    float alpha = texture(glyphAtlas, fragUV).r;
    outColor = vec4(fragColor.rgb, fragColor.a * alpha);
}

@header const m = @import("math.zig")
@ctype mat4 m.Mat4

@vs vs
layout(binding = 0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;

out vec4 color;
out vec2 uv;

void main() {
    gl_Position = mvp * position;
    color = color0;
    uv = texcoord0 * 5.0; 
}
@end

@fs fs

layout(binding = 0) uniform texture2D tex;
layout(binding = 0) uniform sampler smp;

in vec4 color;
in vec2 uv;
out vec4 frag_color;


void main() {
    frag_color = texture(sampler2D(tex, smp), uv) * color;
}
@end

@program cube vs fs

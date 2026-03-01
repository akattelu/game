@header const m = @import("math.zig")
@ctype mat4 m.Mat4

@vs vs
layout(binding = 0) uniform vs_params {
    mat4 mvp;
    float use_texture0;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;
in vec3 normal;

out vec4 color;
out vec2 uv;
out float use_texture;

void main() {
    gl_Position = mvp * position;
    color = color0;
    uv = texcoord0 * 10.0;
    use_texture = use_texture0;
}
@end

@fs fs
layout(binding = 0) uniform texture2D tex;
layout(binding = 0) uniform sampler smp;


in vec4 color;
in vec2 uv;
in float use_texture;
out vec4 frag_color;


void main() {
    vec4 tex_color =  texture(sampler2D(tex, smp), uv);
    frag_color = mix(color, color * tex_color, use_texture);
}
@end

@program terrain vs fs

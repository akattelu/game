@header const m = @import("../lib/math.zig")
@ctype mat4 m.Mat4
@ctype vec3 m.Vec3

@vs vs
layout(binding = 0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;
in vec4 color0;
in vec2 texcoord0;
in vec3 normal;
in vec4 tangent;

out vec4 color;
out vec2 uv;
out vec3 v_normal;
out vec4 v_tangent;

void main() {
    gl_Position = mvp * position;
    color = color0;
    uv = texcoord0;
    v_normal = normal;
    v_tangent = tangent;
}
@end


@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

layout(binding=1) uniform texture2D normal_tex;
layout(binding=1) uniform sampler normal_smp;

layout(binding=2) uniform fs_params {
    vec3 light_dir;
    vec3 light_color;
    float use_texture;
    float use_lighting;
    float use_normal_map;
    float ambient_intensity;
};

in vec4 color;
in vec2 uv;
in vec3 v_normal;
in vec4 v_tangent;
out vec4 frag_color;


void main() {
    vec4 tex_color = texture(sampler2D(tex, smp), uv);
    vec3 N;
    if (use_normal_map == 1.0) {
        vec3 T = normalize(v_tangent.xyz);
        vec3 Nv = normalize(v_normal);
        vec3 B = cross(Nv, T) * v_tangent.w;
        mat3 TBN = mat3(T, B, Nv);

        vec3 map_normal = texture(sampler2D(normal_tex, normal_smp), uv).rgb * 2.0 - 1.0;
        N = normalize(TBN * map_normal);
    } else {
        N = normalize(v_normal);
    }

    if (use_lighting ==  1.0) {
        float diffuse = max(dot(N, normalize(light_dir)), 0.0);
        frag_color = mix(color, color * tex_color, use_texture) * (diffuse + ambient_intensity) * vec4(light_color, 1.0);
    } else {
        frag_color = mix(color, color * tex_color, use_texture);
    }
}
@end

@program gltf vs fs

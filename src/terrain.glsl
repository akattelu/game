@header const m = @import("math.zig")
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

out vec4 color;
out vec2 uv;
out vec3 v_normal;

void main() {
    gl_Position = mvp * position;
    color = color0;
    uv = texcoord0 * 10.0;
    v_normal = normal;
}
@end

@vs vs_gpu
layout(binding = 0) uniform vs_params {
    mat4 mvp;
};

in vec4 position;

out vec4 color;
out vec2 uv;
out vec3 v_normal;

void main() {
    gl_Position = mvp * position;
    uv = vec2(1.0, 1.0);
    v_normal = vec3(1.0, 1.0, 1.0);
}
@end


@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

layout(binding=1) uniform fs_params {
    vec3 light_dir;
    vec3 light_color;
    float use_texture;
    float use_lighting;
    float ambient_intensity;
};

in vec4 color;
in vec2 uv;
in vec3 v_normal;
out vec4 frag_color;


void main() {
    vec4 tex_color = texture(sampler2D(tex, smp), uv);
   
    if (use_lighting ==  1.0) {
        float diffuse = max(dot(normalize(v_normal), normalize(light_dir)), 0.0);
        frag_color = mix(color, color * tex_color, use_texture) * (diffuse + ambient_intensity) * vec4(light_color, 1.0);
    } else {
        frag_color = mix(color, color * tex_color, use_texture);
    }
}
@end

@fs fs_gpu
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

layout(binding=1) uniform fs_params {
    vec3 light_dir;
    vec3 light_color;
    float use_texture;
    float use_lighting;
    float ambient_intensity;
};

in vec4 color;
in vec2 uv;
in vec3 v_normal;
out vec4 frag_color;


void main() {
    vec4 tex_color = texture(sampler2D(tex, smp), uv);
   
    if (use_lighting ==  1.0) {
        float diffuse = max(dot(normalize(v_normal), normalize(light_dir)), 0.0);
        frag_color = mix(color, color * tex_color, use_texture) * (diffuse + ambient_intensity) * vec4(light_color, 1.0);
    } else {
        frag_color = mix(color, color * tex_color, use_texture);
    }
}
@end

@program terrain vs fs

@program terrainGPU vs_gpu fs_gpu

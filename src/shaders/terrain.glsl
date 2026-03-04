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
layout(binding = 0) uniform vs_gpu_params {
    mat4 mvp;

    float frequency;
    float amplitude;
    float lacunarity;
    float persistence;
    int octaves;

    float normal_cell_spacing;

    int u_time;
    int animate;
};

in vec4 position;
in vec2 xz_n;

out vec4 color;
out vec2 uv;
out vec3 v_normal;

float random (in vec2 _st) {
    return fract(sin(dot(_st.xy,
                         vec2(12.9898,78.233)))*
        43758.5453123);
}

float noise (in vec2 _st) {

    float ix = floor(_st.x);
    float iz = floor(_st.y);
    float fx = fract(_st.x);
    float fz = fract(_st.y);

    
    // Smoothstep
    float u = fx * fx * (3.0 - 2.0 * fx);
    float v = fz * fz * (3.0 - 2.0 * fz);

    // Bilinear interpolation of hash values
    float a = random(vec2(ix, iz));
    float b = random(vec2(ix + 1, iz));
    float c = random(vec2(ix, iz + 1));
    float d = random(vec2(ix + 1, iz + 1));

    return mix(mix(a, b, u), mix(c, d, u), v);
}

float fbm ( in vec2 _st) {
    float v = 0.0;
    float freq = frequency;
    float a = amplitude;
    float time_random = abs(sin(u_time * 0.02));
    for (int i = 0; i < octaves; ++i) {
        v += noise(_st * freq) * a;
        if (animate == 1) {
            freq *= (lacunarity + time_random );
        } else {
            freq *= lacunarity;
        }
        a *= persistence;
    }
    return v;
}

bool eq(float x, float y) {
    return abs(x-y) < 0.01;
}

void main() {
    vec4 pos = position;

    // UV from normalized x,z coordinates (position on grid from -1 to 1)
    uv = xz_n;

    // Height calculation randomly with noise
    if (eq(xz_n.x, -1.0) || eq(xz_n.y, -1.0) || eq(xz_n.x, 1.0) || eq(xz_n.y, 1.0)) {
        pos.y = 0.0;
    } else {
        vec2 time_scale = vec2(0.15 * u_time, 0.5 * u_time);
        pos.y = fbm(pos.xz);
    }

    // Position based color gradient
    color = vec4(xz_n.x, xz_n.y, 0.5, 1.0);

    // Calculate normals
    v_normal = vec3(0.5, 0.5, 0.5);
    float epsilon = normal_cell_spacing;
    float hl = fbm(pos.xz + vec2(-epsilon, 0));
    float hr = fbm(pos.xz + vec2(+epsilon, 0));
    float hd = fbm(pos.xz + vec2(0, -epsilon));
    float hu = fbm(pos.xz + vec2(0, +epsilon));

    v_normal = normalize(vec3(hl - hr, normal_cell_spacing, hd - hu));

    // Camera projection
    gl_Position = mvp * pos;
}
@end


@fs fs
// layout(binding=0) uniform texture2D tex;
// layout(binding=0) uniform sampler smp;

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
    // vec4 tex_color = texture(sampler2D(tex, smp), uv);
    vec4 tex_color = color;
   
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

layout(binding=1) uniform fs_gpu_params {
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

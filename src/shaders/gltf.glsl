@header const m = @import("../lib/math.zig")
@ctype mat4 m.Mat4
@ctype vec3 m.Vec3

@vs vs
layout(binding = 0) uniform vs_params {
    mat4 model;
    mat4 view_projection;
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
out vec3 v_world_pos;

void main() {
    vec4 world = model * position;
    gl_Position = view_projection * world;
    v_world_pos = world.xyz;
    color = color0;
    uv = texcoord0;
    v_normal = mat3(model) * normal;
    v_tangent = vec4(mat3(model) * tangent.xyz, tangent.w);

}
@end


@fs fs
#define PI 3.14159265359
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

layout(binding=2) uniform texture2D normal_tex;
layout(binding=2) uniform sampler normal_smp;

layout(binding=3) uniform texture2D mr_tex;
layout(binding=3) uniform sampler mr_smp;

layout(binding=1) uniform fs_params {
    float use_texture;
    float use_lambert_lighting;
    float use_normal_map;
    float use_metallic_roughness_texture;
    vec3 light_dir;
    vec3 light_color;
    float ambient_intensity;

    float metallic_factor;
    float roughness_factor;
    vec3 camera_eye;
};

in vec4 color;
in vec2 uv;
in vec3 v_normal;
in vec4 v_tangent;
in vec3 v_world_pos;
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

    if (use_metallic_roughness_texture == 1.0) {
        vec4 base = mix(color, color * tex_color, use_texture);
        vec2 mr = texture(sampler2D(mr_tex, mr_smp), uv).gb; // green=roughness, blue=metallic
        float roughness = clamp(mr.x * roughness_factor, 0.04, 1.0);
        float metallic = clamp(mr.y * metallic_factor, 0.0, 1.0);

        vec3 V = normalize(camera_eye - v_world_pos);
        vec3 L = normalize(light_dir);
        vec3 H = normalize(V + L);

        float NdotL = max(dot(N, L), 0.0);
        float NdotH = max(dot(N, H), 0.0);
        float NdotV = max(dot(N, V), 0.001);

        // F0: reflectance at normal incidence
        // dielectrics ~0.04, metals use their base color
        vec3 F0 = mix(vec3(0.04), base.rgb, metallic);

        // Fresnel (Schlick)
        vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);

        // Distribution (GGX)
        float a = roughness * roughness;
        float a2 = a * a;
        float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
        float D = a2 / (3.14159 * denom * denom);

        // Geometry (Schlick-GGX, Smith method)
        float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
        float G1_V = NdotV / (NdotV * (1.0 - k) + k);
        float G1_L = NdotL / (NdotL * (1.0 - k) + k);
        float G = G1_V * G1_L;

        vec3 specular = (D * F * G) / (4.0 * NdotV * NdotL + 0.001);

        // Diffuse: only non-metals have diffuse
        vec3 kD = (1.0 - F) * (1.0 - metallic);
        vec3 diffuse = kD * base.rgb / 3.14159;

        frag_color = vec4((diffuse + specular) * NdotL * light_color * PI + base.rgb * ambient_intensity, base.a);
    } else {
        if (use_lambert_lighting ==  1.0) {
            float diffuse = max(dot(N, normalize(light_dir)), 0.0);
            frag_color = mix(color, color * tex_color, use_texture) * (diffuse + ambient_intensity) * vec4(light_color, 1.0);
        } else {
            frag_color = mix(color, color * tex_color, use_texture);
        }

    }


}
@end

@program gltf vs fs

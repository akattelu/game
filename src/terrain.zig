const std = @import("std");
const util = @import("util.zig");
const math = @import("math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const shd = @import("terrain.glsl.zig");
const sokol = @import("sokol");
const ig = @import("cimgui");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const simgui = sokol.imgui;
const sgimgui = sokol.sgimgui;

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: i16,
    v: i16,
    normal: Vec3,
};

const state = struct {
    // General
    pub var mesh_vertices: c_int = 200;
    pub var apply_texture: bool = false;
    pub var seed: f32 = 0.0;

    // Lighting
    pub var apply_lighting: bool = true;
    pub var ambient_intensity: f32 = 0.2;
    pub var normal_cell_spacing: f32 = 2.0;
    pub var azimuth_angle: f32 = 0.0;
    pub var elevation_angle: f32 = 0.0;
    pub var light_color: Vec3 = Vec3.ones();

    // Noise
    pub var frequency: f32 = 0.05;
    pub var amplitude: f32 = 50.0;
    pub var lacunarity: f32 = 8.0;
    pub var persistence: f32 = 0.5;
    pub var octaves: c_int = 4;

    // Camera
    pub var eye: Vec3 = .{ .x = 110.0, .y = 125.0, .z = 30.0 };
    pub var camera_theta: f32 = std.math.pi / 8.0;
    pub var camera_phi: f32 = std.math.pi / 8.0;
    pub var camera_radius: f32 = 175.0;
};

pub fn vertices(allocator: std.mem.Allocator, count: c_int) []Vertex {
    const n: usize = @intCast(count);
    var vs: std.ArrayList(Vertex) = .empty;
    const nf: f32 = @floatFromInt(n);
    const nm: f32 = @floatFromInt(n - 1);
    for (0..n) |i| {
        for (0..n) |j| {
            const r: u8 = @intFromFloat(util.mapRange(@floatFromInt(i), 0, nm, 0, 255));
            const g: u8 = @intFromFloat(util.mapRange(@floatFromInt(j), 0, nm, 0, 255));
            const b: u8 = 128;

            const h: f32 = util.sampleNoise(@floatFromInt(i), @floatFromInt(j), .{
                .frequency = state.frequency,
                .amplitude = state.amplitude,
                .octaves = state.octaves,
                .seed = state.seed,
                .lacunarity = state.lacunarity,
                .persistence = state.persistence,
            });
            const x: f32 = @as(f32, @floatFromInt(i)) - (nf / 2.0);
            const y: f32 = if (i == 0 or j == 0 or i == (n - 1) or j == (n - 1)) 0 else h;
            const z: f32 = @as(f32, @floatFromInt(j)) - (nf / 2.0);
            const color: u32 = util.rgbaToU32(r, g, b, 255);
            const u: i16 = @intFromFloat(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * 32767.0);
            const v: i16 = @intFromFloat(@as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(n)) * 32767.0);
            vs.append(allocator, .{
                .x = x,
                .y = y,
                .z = z,
                .color = color,
                .u = u,
                .v = v,
                .normal = Vec3.zero(),
            }) catch unreachable;
        }
    }

    populateNormals(&vs.items, n);

    return vs.toOwnedSlice(allocator) catch unreachable;
}

pub inline fn indices(allocator: std.mem.Allocator, index_count: c_int) []u16 {
    const n: usize = @intCast(index_count);
    var idx: std.ArrayList(u16) = .empty;
    var count: usize = 0;
    for (0..(n - 1)) |iz| {
        for (0..(n - 1)) |ix| {
            const A: u16 = @intCast(iz * n + ix);
            const B: u16 = @intCast(iz * n + ix + 1);
            const C: u16 = @intCast((iz + 1) * n + ix);
            const D: u16 = @intCast((iz + 1) * n + ix + 1);

            idx.append(allocator, A) catch unreachable;
            idx.append(allocator, C) catch unreachable;
            idx.append(allocator, B) catch unreachable;

            idx.append(allocator, B) catch unreachable;
            idx.append(allocator, C) catch unreachable;
            idx.append(allocator, D) catch unreachable;

            count += 6;
        }
    }
    return idx.toOwnedSlice(allocator) catch unreachable;
}

pub fn ui() void {
    if (ig.igBegin("Terrain Playground", null, ig.ImGuiWindowFlags_AlwaysAutoResize)) {
        if (ig.igBeginTabBar("Settings", 0)) {
            if (ig.igBeginTabItem("General", null, 0)) {
                _ = ig.igSliderInt("Side Length", &state.mesh_vertices, 2, 200);
                _ = ig.igCheckbox("Apply Texture?", &state.apply_texture);
                _ = ig.igSliderFloat("Seed", &state.seed, 0.0, 1000.0);
                ig.igEndTabItem();
            }
            if (ig.igBeginTabItem("Noise", null, 0)) {
                _ = ig.igSliderFloat("Frequency", &state.frequency, 0.0, 1.0);
                _ = ig.igSliderFloat("Amplitude", &state.amplitude, 0.0, 100.0);
                _ = ig.igSliderInt("Octaves", &state.octaves, 1, 8);
                _ = ig.igSliderFloat("Lacunarity", &state.lacunarity, 1.0, 8.0);
                _ = ig.igSliderFloat("Persistence", &state.persistence, 0.1, 1.0);
                ig.igEndTabItem();
            }
            if (ig.igBeginTabItem("Lighting", null, 0)) {
                _ = ig.igCheckbox("Apply Lighting?", &state.apply_lighting);
                _ = ig.igSliderFloat("Cell Spacing", &state.normal_cell_spacing, 0.01, 10.0);
                _ = ig.igSliderFloat("Ambient Light Intensity", &state.ambient_intensity, 0.1, 1.0);
                _ = ig.igSliderFloat("Azimuth Angle", &state.azimuth_angle, 0.0, 2 * std.math.pi);
                _ = ig.igSliderFloat("Elevation angle", &state.elevation_angle, 0.0, std.math.pi / 2.0);
                _ = ig.igColorEdit3("Lighting Color", @ptrCast(&state.light_color), 0);
                ig.igEndTabItem();
            }
            if (ig.igBeginTabItem("Camera", null, 0)) {
                _ = ig.igSliderFloat("Camera Theta", &state.camera_theta, 0.0, 2 * std.math.pi);
                _ = ig.igSliderFloat("Camera Phi", &state.camera_phi, 0.0, 2 * std.math.pi);
                _ = ig.igSliderFloat("Camera Radius", &state.camera_radius, 10.0, 300.0);
                ig.igEndTabItem();
            }
            if (ig.igBeginTabItem("Meta", null, 0)) {
                _ = ig.igBulletText("Dear ImGui Version: %s", ig.IMGUI_VERSION);
                ig.igEndTabItem();
            }
            ig.igEndTabBar();
        }
        ig.igEnd();
    }
}

fn populateNormals(vxs: *[]Vertex, n: usize) void {
    const vs = vxs.*;
    for (0..n) |i| {
        for (0..n) |j| {
            const hl: f32 = vs[index(@max(i, 1) - 1, j, n)].y;
            const hr: f32 = vs[index(@min(i + 1, n - 1), j, n)].y;
            const hd: f32 = vs[index(i, @max(j, 1) - 1, n)].y;
            const hu: f32 = vs[index(i, @min(j + 1, n - 1), n)].y;
            const normal = Vec3.norm(Vec3.new(hl - hr, state.normal_cell_spacing, hd - hu));
            vs[index(i, j, n)].normal = normal;
        }
    }
}

fn index(i: usize, j: usize, n: usize) usize {
    return (i * n) + j;
}

pub fn getState() @TypeOf(state) {
    return state;
}

pub fn getVsParams() shd.VsParams {
    const r = state.camera_radius;
    const phi = state.camera_phi;
    const theta = state.camera_theta;
    return .{
        .mvp = Mat4.mvp(Vec3.new(
            r * @sin(phi) * @cos(theta),
            r * @cos(phi),
            r * @sin(phi) * @sin(theta),
        ), sapp.widthf(), sapp.heightf()),
    };
}

pub fn getFsParams() shd.FsParams {
    return .{
        .light_dir = Vec3.new(
            @cos(state.elevation_angle) * @sin(state.azimuth_angle),
            @sin(state.elevation_angle),
            @cos(state.elevation_angle) * @cos(state.azimuth_angle),
        ),
        .light_color = state.light_color,
        .use_texture = if (state.apply_texture) 1.0 else 0.0,
        .use_lighting = if (state.apply_lighting) 1.0 else 0.0,
        .ambient_intensity = state.ambient_intensity,
    };
}

pub fn getObjectCount() u32 {
    const n: u32 = @intCast(state.mesh_vertices);
    return (n - 1) * (n - 1) * 6;
}

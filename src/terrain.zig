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
    var mesh_vertices: c_int = 10;
    var frequency: f32 = 0.05;
    var amplitude: f32 = 50.0;

    var seed: f32 = 0.0;
    var lacunarity: f32 = 8.0;
    var persistence: f32 = 0.5;
    var octaves: c_int = 4;
};

pub fn vertices(allocator: std.mem.Allocator) sg.Range {
    const n: usize = @intCast(state.mesh_vertices);
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
            const u: i16 = @intFromFloat(@as(f16, @floatFromInt(i)) / @as(f16, @floatFromInt(n)) * 32767.0);
            const v: i16 = @intFromFloat(@as(f16, @floatFromInt(j)) / @as(f16, @floatFromInt(n)) * 32767.0);
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

    const ptr = vs.toOwnedSlice(allocator) catch unreachable;
    return sg.asRange(ptr);
}

pub inline fn indices(allocator: std.mem.Allocator) sg.Range {
    const n: usize = @intCast(state.mesh_vertices);
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
    const ptr = idx.toOwnedSlice(allocator) catch unreachable;
    return sg.asRange(ptr);
}

pub fn ui() void {
    if (ig.igBegin("Terrain Playground", 1, ig.ImGuiWindowFlags_None)) {
        _ = ig.igText("Parameters", ig.IMGUI_VERSION);
        _ = ig.igSliderInt("Side Length", &state.mesh_vertices, 2, 200);
        ig.igSeparator();
        _ = ig.igSliderFloat("Frequency", &state.frequency, 0.0, 1.0);
        _ = ig.igSliderFloat("Amplitude", &state.amplitude, 0.0, 100.0);
        _ = ig.igSliderInt("Octaves", &state.octaves, 1, 8);
        _ = ig.igSliderFloat("Lacunarity", &state.lacunarity, 1.0, 4.0);
        _ = ig.igSliderFloat("Persistence", &state.persistence, 0.1, 1.0);
        ig.igSeparator();
        _ = ig.igSliderFloat("Seed", &state.seed, 0.0, 1000.0);
        ig.igSeparator();
        _ = ig.igText("Metadata", ig.IMGUI_VERSION);
        _ = ig.igBulletText("Dear ImGui Version: %s", ig.IMGUI_VERSION);
    }
    ig.igEnd();
}

pub fn getObjectCount() u32 {
    const n: u32 = @intCast(state.mesh_vertices);
    return (n - 1) * (n - 1) * 6;
}

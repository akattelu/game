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
const builtin = @import("builtin");

fn allocator() std.mem.Allocator {
    if (builtin.cpu.arch.isWasm()) {
        return std.heap.c_allocator;
    } else {
        return std.heap.smp_allocator;
    }
}

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: i16,
    v: i16,
    normal: Vec3,
};

const TerrainState = struct {
    // Pipeline
    bindings: sg.Bindings = .{},
    pipeline: sg.Pipeline = .{},
    pass_action: sg.PassAction = .{},

    // General
    mesh_vertices: c_int = 200,
    apply_texture: bool = false,
    seed: f32 = 0.0,
    animate: bool = false,

    // Lighting
    apply_lighting: bool = true,
    ambient_intensity: f32 = 0.2,
    normal_cell_spacing: f32 = 2.0,
    azimuth_angle: f32 = 0.0,
    elevation_angle: f32 = 0.0,
    light_color: Vec3 = Vec3.ones(),

    // Noise
    frequency: f32 = 0.05,
    amplitude: f32 = 50.0,
    lacunarity: f32 = 1.001,
    persistence: f32 = 0.5,
    octaves: c_int = 4,

    // Camera
    eye: Vec3 = .{ .x = 110.0, .y = 125.0, .z = 30.0 },
    camera_theta: f32 = std.math.pi / 8.0,
    camera_phi: f32 = std.math.pi / 8.0,
    camera_radius: f32 = 175.0,

    // Input
    mouse_down: bool = false,
};

pub fn vertices(alloc: std.mem.Allocator, count: c_int, state: *TerrainState) []Vertex {
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
            vs.append(alloc, .{
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

    populateNormals(&vs.items, n, state);

    return vs.toOwnedSlice(alloc) catch unreachable;
}

pub inline fn indices(alloc: std.mem.Allocator, index_count: c_int) []u16 {
    const n: usize = @intCast(index_count);
    var idx: std.ArrayList(u16) = .empty;
    var count: usize = 0;
    for (0..(n - 1)) |iz| {
        for (0..(n - 1)) |ix| {
            const A: u16 = @intCast(iz * n + ix);
            const B: u16 = @intCast(iz * n + ix + 1);
            const C: u16 = @intCast((iz + 1) * n + ix);
            const D: u16 = @intCast((iz + 1) * n + ix + 1);

            idx.append(alloc, A) catch unreachable;
            idx.append(alloc, C) catch unreachable;
            idx.append(alloc, B) catch unreachable;

            idx.append(alloc, B) catch unreachable;
            idx.append(alloc, C) catch unreachable;
            idx.append(alloc, D) catch unreachable;

            count += 6;
        }
    }
    return idx.toOwnedSlice(alloc) catch unreachable;
}

fn ui(state: *TerrainState) void {
    if (ig.igBeginMainMenuBar()) {
        sgimgui.drawMenu("sokol-gfx");
        ig.igEndMainMenuBar();
    }
    if (ig.igBegin("Terrain Playground", null, ig.ImGuiWindowFlags_AlwaysAutoResize)) {
        if (ig.igBeginTabBar("Settings", 0)) {
            if (ig.igBeginTabItem("General", null, 0)) {
                _ = ig.igSliderInt("Side Length", &state.mesh_vertices, 2, 200);
                _ = ig.igCheckbox("Apply Texture?", &state.apply_texture);
                _ = ig.igSliderFloat("Seed", &state.seed, 0.0, 1000.0);
                ig.igEndTabItem();
            }
            if (ig.igBeginTabItem("Noise", null, 0)) {
                _ = ig.igSliderFloatEx("Frequency", &state.frequency, 0.0, std.math.pi / 4.0, "%2f", ig.ImGuiSliderFlags_Logarithmic);
                _ = ig.igSliderFloat("Amplitude", &state.amplitude, 0.0, 30.0);
                _ = ig.igSliderInt("Octaves", &state.octaves, 1, 8);
                _ = ig.igSliderFloatEx("Lacunarity", &state.lacunarity, 1.0, 4.0, "%2f", ig.ImGuiSliderFlags_Logarithmic);
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

fn populateNormals(vxs: *[]Vertex, n: usize, state: *TerrainState) void {
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

inline fn index(i: usize, j: usize, n: usize) usize {
    return (i * n) + j;
}

pub fn getState() @TypeOf(TerrainState) {
    return TerrainState;
}

fn getVsParams(state: *TerrainState) shd.VsParams {
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

fn getFsParams(state: *TerrainState) shd.FsParams {
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

pub fn getObjectCount(count: c_int) u32 {
    const n: u32 = @intCast(count);
    return (n - 1) * (n - 1) * 6;
}

// fn bindings(userdata: ?*anyopaque) sg.Bindings {}

export fn init(userdata: ?*anyopaque) void {
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });
    simgui.setup(.{ .logger = .{ .func = slog.func } });
    sgimgui.setup(.{});
    sdtx.setup(.{
        .fonts = init: {
            var f: [8]sdtx.FontDesc = @splat(.{});
            f[0] = sdtx.fontKc854();
            break :init f;
        },
        .logger = .{ .func = slog.func },
    });

    var state: *TerrainState = @ptrCast(@alignCast(userdata));
    const alloc = allocator();

    // Construct the grid mesh just so we can size the initial dynamic buffer
    const vertices_range = sg.asRange(vertices(alloc, 200, state));
    const indices_range = sg.asRange(indices(alloc, 200));
    const indexBuffer = sg.makeBuffer(.{ .label = "Mesh Index Buffer", .usage = .{ .dynamic_update = true, .index_buffer = true }, .size = indices_range.size });
    state.bindings.vertex_buffers[0] = sg.makeBuffer(.{ .label = "CPU Heightmap", .usage = .{ .dynamic_update = true, .vertex_buffer = true }, .size = vertices_range.size });
    state.bindings.index_buffer = indexBuffer;
    // create a small checker-board image and texture view
    state.bindings.views[shd.VIEW_tex] = sg.makeView(.{
        .texture = .{
            .image = sg.makeImage(.{
                .width = 4,
                .height = 4,
                .data = init: {
                    var data = sg.ImageData{};
                    data.mip_levels[0] = sg.asRange(&[4 * 4]u32{
                        0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF, 0xFF000000,
                        0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF,
                        0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF, 0xFF000000,
                        0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF,
                    });
                    break :init data;
                },
            }),
        },
    });
    state.bindings.samplers[shd.SMP_smp] = sg.makeSampler(.{});
    state.pipeline = sg.makePipeline(
        .{
            .label = "CPU Noise and Lighting Pipeline",
            .shader = sg.makeShader(shd.terrainShaderDesc(sg.queryBackend())),
            .layout = init: {
                var l = sg.VertexLayoutState{};
                l.attrs[shd.ATTR_terrain_position].format = .FLOAT3;
                l.attrs[shd.ATTR_terrain_color0].format = .UBYTE4N;
                l.attrs[shd.ATTR_terrain_texcoord0].format = .SHORT2N;
                l.attrs[shd.ATTR_terrain_normal].format = .FLOAT3;
                break :init l;
            },
            .index_type = .UINT16,
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
            .cull_mode = .NONE,
        },
    );
}
export fn frame(userdata: ?*anyopaque) void {
    // allocator.free(state.indices.?);
    const state: *TerrainState = @ptrCast(@alignCast(userdata));
    var arena = std.heap.ArenaAllocator.init(allocator());
    defer arena.deinit();
    const alloc = arena.allocator();
    const frame_indices = indices(alloc, state.mesh_vertices);
    const indices_range = sg.asRange(frame_indices);
    sg.updateBuffer(state.bindings.index_buffer, indices_range);

    // allocator.free(state.vertices.?);

    const frame_vertices = vertices(alloc, state.mesh_vertices, state);
    const vertices_range = sg.asRange(frame_vertices);
    sg.updateBuffer(state.bindings.vertex_buffers[0], vertices_range);

    // Setup imgui
    sg.beginPass(.{ .swapchain = sglue.swapchain(), .action = state.pass_action });
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });
    ui(state);

    // Pipeline
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bindings);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&getVsParams(state)));
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&getFsParams(state)));

    // Draw
    sg.draw(0, getObjectCount(state.mesh_vertices), 1);
    sdtx.draw();
    sgimgui.draw();
    simgui.render();

    sg.endPass();
    sg.commit();
}

export fn cleanup(userdata: ?*anyopaque) void {
    _ = userdata;
    sgimgui.shutdown();
    sg.shutdown();
}

export fn event(e: [*c]const sapp.Event, userdata: ?*anyopaque) callconv(.c) void {
    if (simgui.handleEvent(e.*)) {
        return;
    }
    var s: *TerrainState = @ptrCast(@alignCast(userdata));
    switch (e.*.type) {
        .MOUSE_SCROLL => {
            s.camera_radius = @max(10.0, @min(300.0, s.camera_radius + e.*.scroll_y));
        },
        .MOUSE_DOWN => {
            s.mouse_down = true;
        },
        .MOUSE_UP => {
            s.mouse_down = false;
        },
        .MOUSE_MOVE => {
            if (s.mouse_down) {
                s.camera_phi = s.camera_phi + (-0.01 * e.*.mouse_dy); // Negative coefficient will reverse drag direction
                s.camera_theta = s.camera_theta + (0.01 * e.*.mouse_dx);
            }
        },
        .KEY_DOWN => {
            switch (e.*.key_code) {
                .Q => sapp.quit(),
                else => {},
            }
        },
        else => {},
    }
}

pub fn main() !void {
    var state = TerrainState{};
    sapp.run(.{
        .init_userdata_cb = init,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .user_data = @ptrCast(&state),
        .width = 1280,
        .height = 960,
        .icon = .{ .sokol_default = true },
        .window_title = "game",
        .sample_count = 4,
        .logger = .{ .func = slog.func },
        .html5 = .{ .canvas_selector = "#canvas" },
        .high_dpi = true,
    });
}

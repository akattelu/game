const Gltf = @import("zgltf").Gltf;
const std = @import("std");
const util = @import("lib/util.zig");
const math = @import("lib/math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const shd = @import("shaders/terrain.glsl.zig");
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
const print = std.debug.print;

inline fn allocator() std.mem.Allocator {
    if (builtin.cpu.arch.isWasm()) {
        return std.heap.c_allocator;
    } else {
        return std.heap.smp_allocator;
    }
}

var st: GltfViewer = .{};
const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: i16,
    v: i16,
    normal: Vec3,
};
pub const GltfViewer = struct {
    // GLTF Core
    gltf_mesh_vertices: ?[]Vertex = null,
    gltf_mesh_indices: ?[]u16 = null,

    // Camera
    eye: Vec3 = .{ .x = 110.0, .y = 125.0, .z = 30.0 },
    camera_theta: f32 = std.math.pi / 8.0,
    camera_phi: f32 = std.math.pi / 8.0,
    camera_radius: f32 = 175.0,
    mouse_down: bool = false,

    // Sokol bindings
    bindings: sg.Bindings = .{},
    pipeline: sg.Pipeline = .{},
    pass_action: sg.PassAction = .{},

    // Lighting
    apply_texture: bool = false,
    apply_lighting: bool = true,
    ambient_intensity: f32 = 0.2,
    normal_cell_spacing: f32 = 2.0,
    azimuth_angle: f32 = 0.0,
    elevation_angle: f32 = 0.0,
    light_color: Vec3 = Vec3.ones(),

    pub fn populate(self: *GltfViewer, alloc: std.mem.Allocator, path: []const u8) !void {
        const buffer = try std.fs.cwd().readFileAllocOptions(
            alloc,
            path,
            512_000_000,
            null,
            .@"4",
            null,
        );
        defer alloc.free(buffer);

        var vertices: std.ArrayList(Vertex) = .empty;
        var indices: std.ArrayList(u16) = .empty;

        var gltf = Gltf.init(alloc);
        defer gltf.deinit();

        try gltf.parse(buffer);

        for (gltf.data.meshes) |mesh| {
            print("Mesh Name: {?s}\n\n", .{mesh.name});
            for (mesh.primitives, 0..) |primitive, idx| {
                print("Primitive #{d}, mode: {s}\n", .{ idx, @tagName(primitive.mode) });
                for (primitive.attributes) |attr| {
                    switch (attr) {
                        .position => |pos| {
                            const accessor = gltf.data.accessors[pos];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            while (it.next()) |v| {
                                try vertices.append(alloc, .{
                                    .x = v[0],
                                    .y = v[1],
                                    .z = v[2],
                                    .normal = Vec3.new(1.0, 0.0, 0.0),
                                    .color = util.rgbaToU32(255, 255, 255, 255),
                                    .u = 0,
                                    .v = 0,
                                });
                            }
                        },
                        .normal => |normal| {
                            const accessor = gltf.data.accessors[normal];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1) {
                                vertices.items[i].normal = Vec3.new(n[0], n[1], n[2]);
                            }
                        },
                        .color => |color| {
                            const accessor = gltf.data.accessors[color];
                            var it = accessor.iterator(u32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1) {
                                vertices.items[i].color = n[0];
                            }
                        },
                        .texcoord => |texcoord| {
                            print("Primitive texcoord: {any}\n", .{texcoord});
                        },
                        else => {},
                    }
                }
                if (primitive.indices) |prim_indices| {
                    const accessor = gltf.data.accessors[prim_indices];
                    var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                    while (it.next()) |i| {
                        try indices.append(alloc, i[0]);
                    }
                }
                print("\n", .{});
            }
            break;
        }

        gltf.debugPrint();
        self.gltf_mesh_vertices = try vertices.toOwnedSlice(alloc);
        self.gltf_mesh_indices = try indices.toOwnedSlice(alloc);
    }
    fn vsUniforms(self: *GltfViewer) shd.VsParams {
        const r = self.camera_radius;
        const phi = self.camera_phi;
        const theta = self.camera_theta;
        return .{
            .mvp = Mat4.mvp(Vec3.new(
                r * @sin(phi) * @cos(theta),
                r * @cos(phi),
                r * @sin(phi) * @sin(theta),
            ), sapp.widthf(), sapp.heightf()),
        };
    }

    fn fsUniforms(self: *GltfViewer) shd.FsParams {
        return .{
            .light_dir = Vec3.new(
                @cos(self.elevation_angle) * @sin(self.azimuth_angle),
                @sin(self.elevation_angle),
                @cos(self.elevation_angle) * @cos(self.azimuth_angle),
            ),
            .light_color = self.light_color,
            .use_texture = if (self.apply_texture) 1.0 else 0.0,
            .use_lighting = if (self.apply_lighting) 1.0 else 0.0,
            .ambient_intensity = self.ambient_intensity,
        };
    }
};

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

    const state: *GltfViewer = @ptrCast(@alignCast(userdata));

    // Construct the grid mesh just so we can size the initial dynamic buffer
    state.bindings.vertex_buffers[0] = sg.makeBuffer(.{
        .label = "GLTF Mesh Vertices Data",
        .usage = .{ .vertex_buffer = true },
        .data = sg.asRange(state.gltf_mesh_vertices.?),
    });
    state.bindings.index_buffer = sg.makeBuffer(.{
        .label = "GLTF Mesh Indices Data",
        .usage = .{ .index_buffer = true },
        .data = sg.asRange(state.gltf_mesh_indices.?),
    });
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
    var arena = std.heap.ArenaAllocator.init(allocator());
    defer arena.deinit();
    const state: *GltfViewer = @ptrCast(@alignCast(userdata));

    // Setup imgui
    sg.beginPass(.{ .swapchain = sglue.swapchain(), .action = state.pass_action });
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    // Pipeline
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bindings);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&state.vsUniforms()));
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&state.fsUniforms()));

    // Draw
    sg.draw(0, @intCast(state.gltf_mesh_indices.?.len), 1);
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
    var s: *GltfViewer = @ptrCast(@alignCast(userdata));
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
    const alloc = allocator();
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();
    _ = iter.next();
    const arg = iter.next();
    if (arg) |path| {
        std.debug.print("arg: {?s}\n", .{arg});
        try st.populate(alloc, path);
    }
    sapp.run(.{
        .init_userdata_cb = init,
        .frame_userdata_cb = frame,
        .cleanup_userdata_cb = cleanup,
        .event_userdata_cb = event,
        .user_data = @ptrCast(&st),
        .width = 1280,
        .height = 960,
        .icon = .{ .sokol_default = true },
        .window_title = "GLTF Viewer",
        .sample_count = 4,
        .logger = .{ .func = slog.func },
        .html5 = .{ .canvas_selector = "#canvas" },
        .high_dpi = true,
    });
}

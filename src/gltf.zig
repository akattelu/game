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

const Primitive = struct {
    binding: sg.Bindings = .{},
    object_count: u32 = 0,
};

pub const GltfViewer = struct {
    // GLTF Core
    primitives: ?[]Primitive = null,
    gltf: ?Gltf = null,
    selected_index: ?usize = null,

    // Other UI
    imgui_window_open: bool = true,

    // Camera
    eye: Vec3 = .{ .x = 110.0, .y = 125.0, .z = 30.0 },
    camera_theta: f32 = std.math.pi / 8.0,
    camera_phi: f32 = std.math.pi / 8.0,
    camera_radius: f32 = 175.0,
    mouse_down: bool = false,

    // Sokol bindings
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

    pub fn loadGlb(self: *GltfViewer, alloc: std.mem.Allocator, path: []const u8) !void {
        const buffer = try std.fs.cwd().readFileAllocOptions(alloc, path, 512_000_000, null, .@"4", null);

        var gltf = Gltf.init(alloc);
        try gltf.parse(buffer);
        self.gltf = gltf;
    }

    pub fn initPrimitives(self: *GltfViewer, alloc: std.mem.Allocator) !void {
        var primitives: std.ArrayList(Primitive) = .empty;
        const gltf = self.gltf.?;
        const mesh = gltf.data.meshes[0];

        for (mesh.primitives, 0..) |primitive, prim_idx| {
            _ = prim_idx;
            var bindings: sg.Bindings = .{};
            var vertices: std.ArrayList(Vertex) = .empty;
            var indices: std.ArrayList(u16) = .empty;
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
                if (accessor.component_type == .unsigned_short) {
                    var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                    while (it.next()) |i| {
                        try indices.append(alloc, i[0]);
                    }
                }
            }

            const owned_indices = try indices.toOwnedSlice(alloc);
            bindings.vertex_buffers[0] = sg.makeBuffer(.{
                .label = "Primitive Vertex Buffer",
                .usage = .{ .vertex_buffer = true },
                .data = sg.asRange(try vertices.toOwnedSlice(alloc)),
            });
            bindings.index_buffer = sg.makeBuffer(.{
                .label = "Primitive Index Buffer",
                .usage = .{ .index_buffer = true },
                .data = sg.asRange(owned_indices),
            });
            bindings.views[shd.VIEW_tex] = sg.makeView(.{
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
            bindings.samplers[shd.SMP_smp] = sg.makeSampler(.{});
            try primitives.append(alloc, .{ .binding = bindings, .object_count = @intCast(owned_indices.len) });
        }

        gltf.debugPrint();
        self.primitives = try primitives.toOwnedSlice(alloc);
    }

    pub fn deinit(self: *GltfViewer, alloc: std.mem.Allocator) void {
        alloc.free(self.gltf_mesh_indices);
        alloc.free(self.gltf_mesh_vertices);
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

    fn ui(self: *GltfViewer) void {
        if (ig.igBeginMainMenuBar()) {
            sgimgui.drawMenu("sokol-gfx");
            ig.igEndMainMenuBar();
        }
        if (ig.igBegin("GLTF/GLB Viewer", &self.imgui_window_open, ig.ImGuiWindowFlags_AlwaysAutoResize)) {
            if (ig.igBeginTabBar("Settings", 0)) {
                if (ig.igBeginTabItem("General", null, 0)) {
                    _ = ig.igText("Total number of primitives in file: %d", self.primitives.?.len);
                    _ = ig.igText("Primitive Count: %d", self.primitives.?.len);
                    if (self.selected_index) |idx| {
                        _ = ig.igText("Now viewing primitive number: %d", idx);
                    } else {
                        _ = ig.igText("Now viewing all primitives drawn together");
                    }
                    if (ig.igArrowButton("Primitive Right", ig.ImGuiDir_Right)) {
                        if (self.selected_index) |idx| {
                            if (idx + 1 >= self.primitives.?.len) {
                                self.selected_index = null;
                            } else {
                                self.selected_index.? += 1;
                            }
                        } else {
                            self.selected_index = 0;
                        }
                    }
                    ig.igEndTabItem();
                }
                if (ig.igBeginTabItem("Meta", null, 0)) {
                    _ = ig.igBulletText("Dear ImGui Version: %s", ig.IMGUI_VERSION);
                    ig.igEndTabItem();
                }
                if (ig.igBeginTabItem("Lighting", null, 0)) {
                    _ = ig.igCheckbox("Apply Lighting?", &self.apply_lighting);
                    _ = ig.igSliderFloat("Cell Spacing", &self.normal_cell_spacing, 0.01, 10.0);
                    _ = ig.igSliderFloat("Ambient Light Intensity", &self.ambient_intensity, 0.1, 1.0);
                    _ = ig.igSliderFloat("Azimuth Angle", &self.azimuth_angle, 0.0, 2 * std.math.pi);
                    _ = ig.igSliderFloat("Elevation angle", &self.elevation_angle, 0.0, std.math.pi / 2.0);
                    _ = ig.igColorEdit3("Lighting Color", @ptrCast(&self.light_color), 0);
                    ig.igEndTabItem();
                }
                if (ig.igBeginTabItem("Camera", null, 0)) {
                    _ = ig.igSliderFloat("Camera Theta", &self.camera_theta, 0.0, 2 * std.math.pi);
                    _ = ig.igSliderFloat("Camera Phi", &self.camera_phi, 0.0, 2 * std.math.pi);
                    _ = ig.igSliderFloat("Camera Radius", &self.camera_radius, 10.0, 900.0);
                    ig.igEndTabItem();
                }
                ig.igEndTabBar();
            }
        }
        ig.igEnd();
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
    state.initPrimitives(allocator()) catch {
        @panic("Failed to initialize primitives");
    };

    state.pipeline = sg.makePipeline(
        .{
            .label = "CPU Noise and Normal Calculation Pipeline",
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

    state.ui();

    // Pipeline
    sg.applyPipeline(state.pipeline);
    if (state.selected_index) |idx| {
        const prim = state.primitives.?[idx];
        sg.applyBindings(prim.binding);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&state.vsUniforms()));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&state.fsUniforms()));
        sg.draw(0, prim.object_count, 1);
    } else {
        for (state.primitives.?) |prim| {
            sg.applyBindings(prim.binding);
            sg.applyUniforms(shd.UB_vs_params, sg.asRange(&state.vsUniforms()));
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&state.fsUniforms()));
            sg.draw(0, prim.object_count, 1);
        }
    }

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
    if (iter.next()) |path| {
        try st.loadGlb(alloc, path);
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

const Gltf = @import("zgltf").Gltf;
const std = @import("std");
const util = @import("lib/util.zig");
const math = @import("lib/math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const shd = @import("shaders/gltf.glsl.zig");
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
const zigimg = @import("zigimg");
const print = std.debug.print;
const sprint = std.fmt.allocPrint;

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
    tangent: Vec4,
};

const Primitive = struct {
    binding: sg.Bindings = .{},
    object_count: u32 = 0,
    y_max: f32 = 0.0,
    y_min: f32 = 0.0,
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    has_normal_map_data: bool = false,
    has_metallic_roughness_texture: bool = false,
};

const Mesh = struct {
    name: ?[]const u8,
    primitives: []Primitive,
};

pub const GltfViewer = struct {
    // GLTF Core
    meshes: ?[]Mesh = null,
    gltf: ?Gltf = null,
    selected_mesh_index: usize = 0,

    // Other UI
    imgui_window_open: bool = true,

    // Camera
    eye: Vec3 = .{ .x = 110.0, .y = 125.0, .z = 30.0 },
    camera_theta: f32 = 1.276,
    camera_phi: f32 = 0.785,
    camera_radius: f32 = 50.0,
    mouse_down: bool = false,

    // Sokol bindings
    pipeline: sg.Pipeline = .{},
    pass_action: sg.PassAction = .{},

    // Lighting
    apply_texture: bool = true,
    apply_normal_map: bool = false,
    apply_metallic_roughness_texture: bool = false,
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
        var meshes: std.ArrayList(Mesh) = .empty;

        for (gltf.data.meshes) |mesh| {
            for (mesh.primitives, 0..) |primitive, prim_idx| {
                var bindings: sg.Bindings = .{};
                var vertices: std.ArrayList(Vertex) = .empty;
                var indices: std.ArrayList(u16) = .empty;
                var obj_count: u32 = 0;
                var y_max: f32 = 0;
                var y_min: f32 = 0;
                var has_normal_map_data: bool = false;
                var has_metallic_roughness_texture: bool = false;
                var metallic_factor: f32 = 0.0;
                var roughness_factor: f32 = 0.0;

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
                                    .tangent = Vec4.new(0, 0, 0, 0),
                                });
                                if (v[1] > y_max) y_max = v[1];
                                if (v[1] < y_min) y_min = v[1];
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
                            // _ = color;
                            const accessor = gltf.data.accessors[color];
                            var it = accessor.iterator(u32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1) {
                                vertices.items[i].color = n[0];
                            }
                        },
                        .tangent => |tangent| {
                            const accessor = gltf.data.accessors[tangent];
                            sdtx.print("Loading tangent values for primitive {d}\n", .{prim_idx});
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1) {
                                vertices.items[i].tangent = Vec4.new(n[0], n[1], n[2], n[3]);
                            }
                            has_normal_map_data = true;
                        },
                        .texcoord => |texcoord| {
                            const accessor = gltf.data.accessors[texcoord];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |uv| : (i += 1) {
                                vertices.items[i].u = @intFromFloat(uv[0] * 32767.0);
                                vertices.items[i].v = @intFromFloat(uv[1] * 32767.0);
                            }
                        },
                        else => {},
                    }
                }
                // Load vertex buffer with all info from parsing vertex attributes
                bindings.vertex_buffers[0] = sg.makeBuffer(.{
                    .label = "Primitive Vertex Buffer",
                    .usage = .{ .vertex_buffer = true },
                    .data = sg.asRange(try vertices.toOwnedSlice(alloc)),
                });

                // Read and load indices
                if (primitive.indices) |prim_indices| {
                    const accessor = gltf.data.accessors[prim_indices];
                    if (accessor.component_type == .unsigned_short) {
                        var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                        while (it.next()) |i| {
                            try indices.append(alloc, i[0]);
                        }
                    }

                    const owned_indices = try indices.toOwnedSlice(alloc);
                    bindings.index_buffer = sg.makeBuffer(.{
                        .label = "Primitive Index Buffer",
                        .usage = .{ .index_buffer = true },
                        .data = sg.asRange(owned_indices),
                    });
                    obj_count = @intCast(owned_indices.len);
                }

                // Material processing
                if (primitive.material) |mat_idx| {
                    const material = gltf.data.materials[mat_idx];
                    metallic_factor = material.metallic_roughness.metallic_factor;
                    roughness_factor = material.metallic_roughness.roughness_factor;
                    // Load base color texture image
                    var normal_map_texture_image: sg.Image = .{};
                    if (material.normal_texture) |tex| {
                        sdtx.print("Loading normal map texture for primitive {d}\n", .{prim_idx});
                        const encoded_bytes = gltf.data.images[gltf.data.textures[tex.index].source.?].data.?;
                        normal_map_texture_image = try makeSgImage(alloc, encoded_bytes);
                    } else {
                        normal_map_texture_image = sg.makeImage(.{ .label = "Dummy base normal map texture image", .width = 1, .height = 1, .data = init: {
                            var data = sg.ImageData{};
                            data.mip_levels[0] = sg.asRange(&[1]u32{
                                0xFFFF8080,
                            });
                            break :init data;
                        } });
                        has_normal_map_data = false;
                    }
                    bindings.views[shd.VIEW_normal_tex] = sg.makeView(.{
                        .label = (try sprint(alloc, "{s} Normal Map Texture for primitive {d}", .{ material.name.?, prim_idx })).ptr,
                        .texture = .{ .image = normal_map_texture_image },
                    });

                    // Load base color texture image
                    var base_color_texture_image: sg.Image = .{};
                    if (material.metallic_roughness.base_color_texture) |tex| {
                        const encoded_bytes = gltf.data.images[gltf.data.textures[tex.index].source.?].data.?;
                        base_color_texture_image = try makeSgImage(alloc, encoded_bytes);
                    } else {
                        base_color_texture_image = sg.makeImage(.{ .label = "Dummy base color texture image", .width = 1, .height = 1, .data = init: {
                            var data = sg.ImageData{};
                            data.mip_levels[0] = sg.asRange(&[1]u32{
                                0xFFFFFFFF,
                            });
                            break :init data;
                        } });
                    }
                    bindings.views[shd.VIEW_tex] = sg.makeView(.{
                        .label = (try sprint(alloc, "{s} Metallic Roughness Base Texture for primitive {d}", .{ material.name.?, prim_idx })).ptr,
                        .texture = .{ .image = base_color_texture_image },
                    });

                    // Load metallic roughness texture image
                    var metallic_roughness_texture_image: sg.Image = .{};
                    if (material.metallic_roughness.metallic_roughness_texture) |tex| {
                        const encoded_bytes = gltf.data.images[gltf.data.textures[tex.index].source.?].data.?;
                        metallic_roughness_texture_image = try makeSgImage(alloc, encoded_bytes);
                        has_metallic_roughness_texture = true;
                    } else {
                        metallic_roughness_texture_image = sg.makeImage(.{ .label = "Dummy mr texture image", .width = 1, .height = 1, .data = init: {
                            var data = sg.ImageData{};
                            data.mip_levels[0] = sg.asRange(&[1]u32{0xFFFFFFFF});
                            break :init data;
                        } });
                    }
                    bindings.views[shd.VIEW_mr_tex] = sg.makeView(.{
                        .label = (try sprint(alloc, "{s} Metallic Roughness Texture for primitive {d}", .{ material.name.?, prim_idx })).ptr,
                        .texture = .{ .image = metallic_roughness_texture_image },
                    });
                }

                bindings.samplers[shd.SMP_smp] = sg.makeSampler(.{});
                bindings.samplers[shd.SMP_normal_smp] = sg.makeSampler(.{});
                bindings.samplers[shd.SMP_mr_smp] = sg.makeSampler(.{});

                try primitives.append(alloc, .{
                    .binding = bindings,
                    .object_count = obj_count,
                    .y_max = y_max,
                    .y_min = y_min,
                    .has_normal_map_data = has_normal_map_data,
                    .has_metallic_roughness_texture = has_metallic_roughness_texture,
                    .metallic_factor = metallic_factor,
                    .roughness_factor = roughness_factor,
                });
            }

            gltf.debugPrint();
            const mesh_primitives = try primitives.toOwnedSlice(alloc);
            try meshes.append(alloc, .{
                .name = mesh.name,
                .primitives = mesh_primitives,
            });
        }
        self.meshes = try meshes.toOwnedSlice(alloc);
    }

    fn vsUniforms(self: *GltfViewer, prim: *const Primitive) shd.VsParams {
        const r = self.camera_radius;
        const phi = self.camera_phi;
        const theta = self.camera_theta;
        const center_y = (prim.y_min + prim.y_max) / 2.0;
        const model = Mat4.translate(Vec3.new(0, -center_y, 0));
        return .{
            .mvp = Mat4.mvp(
                Vec3.new(
                    r * @sin(phi) * @cos(theta),
                    r * @cos(phi),
                    r * @sin(phi) * @sin(theta),
                ),
                sapp.widthf(),
                sapp.heightf(),
                model,
            ),
        };
    }

    fn fsUniforms(self: *GltfViewer, prim: *const Primitive) shd.FsParams {
        return .{
            .light_dir = Vec3.new(
                @cos(self.elevation_angle) * @sin(self.azimuth_angle),
                @sin(self.elevation_angle),
                @cos(self.elevation_angle) * @cos(self.azimuth_angle),
            ),
            .light_color = self.light_color,
            .use_texture = if (self.apply_texture) 1.0 else 0.0,
            .use_lambert_lighting = if (self.apply_lighting) 1.0 else 0.0,
            .use_normal_map = if (self.apply_normal_map and prim.has_normal_map_data) 1.0 else 0.0,
            .ambient_intensity = self.ambient_intensity,
            .metallic_factor = prim.metallic_factor,
            .roughness_factor = prim.roughness_factor,
            .use_metallic_roughness_texture = if (self.apply_metallic_roughness_texture and prim.has_metallic_roughness_texture) 1.0 else 0.0,
            .camera_eye = self.eye,
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
                    _ = ig.igText("Mesh Count: %d", self.meshes.?.len);
                    _ = ig.igText("Now viewing mesh number: %d", self.selected_mesh_index);
                    _ = ig.igCheckbox("Apply Texture?", &self.apply_texture);
                    for (self.meshes.?[self.selected_mesh_index].primitives) |prim| {
                        if (prim.has_normal_map_data) {
                            // Will run once per primitive but its fine
                            _ = ig.igCheckbox("Apply Normal Map?", &self.apply_normal_map);
                        }
                        if (prim.has_metallic_roughness_texture) {
                            _ = ig.igCheckbox("Apply Metallic Roughness Texture?", &self.apply_metallic_roughness_texture);
                        }
                    }

                    if (ig.igArrowButton("Previous Mesh", ig.ImGuiDir_Left)) {
                        if (self.selected_mesh_index != 0) {
                            self.selected_mesh_index = self.selected_mesh_index - 1;
                        }
                    }
                    if (ig.igArrowButton("Next Mesh", ig.ImGuiDir_Right)) {
                        self.selected_mesh_index = @min(self.selected_mesh_index + 1, self.meshes.?.len - 1);
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
                    _ = ig.igSliderFloatEx("Camera Radius", &self.camera_radius, 1.0, 900.0, "%2f", ig.ImGuiSliderFlags_Logarithmic);
                    ig.igEndTabItem();
                }
                ig.igEndTabBar();
            }
        }
        ig.igEnd();
    }
};

pub fn makeSgImage(alloc: std.mem.Allocator, buffer: []const u8) !sg.Image {
    var img = try zigimg.Image.fromMemory(alloc, buffer);
    const w: i32 = @intCast(img.width);
    const h: i32 = @intCast(img.height);
    try img.convert(alloc, .rgba32);
    const img_pixels = img.rawBytes();
    return sg.makeImage(.{
        .width = w,
        .height = h,
        .pixel_format = .RGBA8,
        .data = init: {
            var data = sg.ImageData{};
            data.mip_levels[0] = sg.asRange(img_pixels);
            break :init data;
        },
    });
}

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
            .shader = sg.makeShader(shd.gltfShaderDesc(sg.queryBackend())),
            .layout = init: {
                var l = sg.VertexLayoutState{};
                l.attrs[shd.ATTR_gltf_position].format = .FLOAT3;
                l.attrs[shd.ATTR_gltf_color0].format = .UBYTE4N;
                l.attrs[shd.ATTR_gltf_texcoord0].format = .SHORT2N;
                l.attrs[shd.ATTR_gltf_normal].format = .FLOAT3;
                l.attrs[shd.ATTR_gltf_tangent].format = .FLOAT4;
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
    _ = arena.allocator();

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
    const mesh = state.meshes.?[state.selected_mesh_index];
    for (mesh.primitives) |prim| {
        sg.applyBindings(prim.binding);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&state.vsUniforms(&prim)));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&state.fsUniforms(&prim)));
        sg.draw(0, prim.object_count, 1);
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
            s.camera_radius = @max(1.0, @min(600.0, s.camera_radius + e.*.scroll_y));
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

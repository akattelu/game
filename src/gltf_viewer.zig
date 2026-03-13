const std = @import("std");
const print = std.debug.print;
const sprint = std.fmt.allocPrint;
const builtin = @import("builtin");

const Gltf = @import("zgltf").Gltf;
const ig = @import("cimgui");
const sokol = @import("sokol");
const sfetch = sokol.fetch;
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const simgui = sokol.imgui;
const sgimgui = sokol.sgimgui;
const zigimg = @import("zigimg");

const math = @import("lib/math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const util = @import("lib/util.zig");
const shd = @import("shaders/gltf.glsl.zig");
const gltf_loader = @import("lib/gltf_loader.zig");
const GltfModel = gltf_loader.GltfModel;
const Vertex = gltf_loader.Vertex;
const Primitive = gltf_loader.Primitive;
const Node = gltf_loader.Node;

inline fn allocator() std.mem.Allocator {
    return if (builtin.cpu.arch.isWasm()) std.heap.c_allocator else std.heap.smp_allocator;
}

var st: GltfViewer = .{};
var sfetch_buffer: [100 * 1024 * 1024]u8 align(4) = undefined;

const NUM_ASSETS = 9;
const available_assets: [NUM_ASSETS][]const u8 = .{
    "CompareMetallic.glb",
    "CompareNormal.glb",
    "CompareRoughness.glb",
    "NormalTangentMirrorTest.glb",
    "Skely.glb",
    "StairsXL.glb",
    "street.glb",
    "Skeleton_Mage.glb",
    "CesiumMilkTruck.glb",
};

const GltfViewer = struct {
    // GLTF Core
    model: ?GltfModel = null,
    scene_root_index: ?usize = null,

    // Asset loader
    assets_selection_state: [NUM_ASSETS]bool = undefined,
    selected_asset_index: ?usize = null,

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
    apply_normal_map: bool = true,
    apply_metallic_roughness_texture: bool = true,
    apply_lighting: bool = true,
    ambient_intensity: f32 = 0.2,
    normal_cell_spacing: f32 = 2.0,
    azimuth_angle: f32 = 0.0,
    elevation_angle: f32 = 0.0,
    light_color: Vec3 = Vec3.ones(),

    pub fn loadGlb(self: *GltfViewer, alloc: std.mem.Allocator, range: sfetch.Range) !void {
        if (self.model) |*model| {
            model.deinit();
        }
        const buffer: [*]align(4) const u8 = @ptrCast(@alignCast(range.ptr.?));
        const slice: []align(4) const u8 = buffer[0..range.size];

        self.model = try .init(alloc, slice);
        self.scene_root_index = 0;
    }

    fn vsUniforms(self: *GltfViewer, prim: *const Primitive, model: Mat4) shd.VsParams {
        const r = self.camera_radius;
        const phi = self.camera_phi;
        const theta = self.camera_theta;
        _ = prim;
        return .{
            .view_projection = Mat4.vp(
                Vec3.new(
                    r * @sin(phi) * @cos(theta),
                    r * @cos(phi),
                    r * @sin(phi) * @sin(theta),
                ),
                sapp.widthf(),
                sapp.heightf(),
            ),
            .model = model,
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

    fn ui(self: *GltfViewer, alloc: std.mem.Allocator) void {
        if (ig.igBeginMainMenuBar()) {
            sgimgui.drawMenu("sokol-gfx");
            ig.igEndMainMenuBar();
        }
        if (ig.igBegin("GLTF/GLB Viewer", &self.imgui_window_open, ig.ImGuiWindowFlags_AlwaysAutoResize)) {
            if (ig.igBeginTabBar("Settings", 0)) {
                if (self.model) |_| { // Only if mesh is already loaded
                    if (ig.igBeginTabItem("General", null, 0)) {
                        _ = ig.igCheckbox("Apply Texture?", &self.apply_texture);
                        if (self.scene_root_index) |root_idx| {
                            _ = ig.igText("Viewing root: %d", root_idx);
                            if (ig.igButton("Prev root")) {}
                            if (ig.igButton("Next root")) {
                                self.scene_root_index = @min(root_idx + 1, self.model.?.scene_trees.len - 1);
                            }
                        }
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
                }
                if (ig.igBeginTabItem("Loader", null, 0)) {
                    const preview = if (self.selected_asset_index) |a| available_assets[a] else "Pick a file...";
                    if (ig.igBeginCombo("Select an asset to load", preview.ptr, 0)) {
                        for (&self.assets_selection_state, 0..) |*selected, i| {
                            if (ig.igSelectableBoolPtr(available_assets[i].ptr, selected, 0)) {
                                self.selected_asset_index = i;
                                self.initiateAssetFetch(alloc) catch @panic("Failed to fetch asset");
                            }
                        }
                        ig.igEndCombo();
                    }
                    ig.igEndTabItem();
                }

                if (ig.igBeginTabItem("Meta", null, 0)) {
                    _ = ig.igBulletText("Dear ImGui Version: %s", ig.IMGUI_VERSION);
                    ig.igEndTabItem();
                }

                if (ig.igBeginTabItem("Camera", null, 0)) {
                    _ = ig.igSliderFloat("Camera Theta", &self.camera_theta, 0.0, 2 * std.math.pi);
                    _ = ig.igSliderFloat("Camera Phi", &self.camera_phi, 0.0, 2 * std.math.pi);
                    _ = ig.igSliderFloatEx("Camera Radius", &self.camera_radius, 0.00001, 1000.0, "%2f", ig.ImGuiSliderFlags_Logarithmic);
                    ig.igEndTabItem();
                }
                ig.igEndTabBar();
            }
        }
        ig.igEnd();
    }

    fn initiateAssetFetch(self: *GltfViewer, alloc: std.mem.Allocator) !void {
        if (self.selected_asset_index) |idx| {
            const path = try std.fmt.allocPrintSentinel(alloc, "assets/{s}", .{available_assets[idx]}, 0);
            std.debug.assert(sfetch.valid());
            _ = sfetch.send(.{
                .path = path.ptr,
                .callback = onAssetResponse,
                .buffer = .{ .ptr = &sfetch_buffer, .size = sfetch_buffer.len },
            });
        }
    }
};

export fn onAssetResponse(response: [*c]const sfetch.Response) void {
    const r = response.*;
    if (r.fetched) {
        st.loadGlb(allocator(), r.buffer) catch @panic("Fetch failed");
    }
    if (r.finished) {
        if (r.failed) {
            std.debug.panic("onAssetResponse: fetch failed {s}", .{@tagName(r.error_code)});
        }
    }
}

export fn init(userdata: ?*anyopaque) void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
        .buffer_pool_size = 1024,
        .image_pool_size = 256,
        .sampler_pool_size = 256,
    });
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
    sfetch.setup(.{
        .max_requests = 8,
        .num_channels = 1,
        .num_lanes = 4,
        .logger = .{ .func = slog.func },
    });

    const state: *GltfViewer = @ptrCast(@alignCast(userdata));

    state.pipeline = sg.makePipeline(
        .{
            .label = "GLTF Viewer Pipeline",
            .shader = sg.makeShader(shd.gltfShaderDesc(sg.queryBackend())),
            .layout = init: {
                var l = sg.VertexLayoutState{};
                l.attrs[shd.ATTR_gltf_position].format = .FLOAT3;
                l.attrs[shd.ATTR_gltf_color0].format = .UBYTE4N;
                l.attrs[shd.ATTR_gltf_texcoord0].format = .SHORT2N;
                l.attrs[shd.ATTR_gltf_normal].format = .FLOAT3;
                l.attrs[shd.ATTR_gltf_tangent].format = .FLOAT4;
                l.attrs[shd.ATTR_gltf_joints].format = .UBYTE4;
                l.attrs[shd.ATTR_gltf_weights].format = .FLOAT4;
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
    const alloc = arena.allocator();
    const state: *GltfViewer = @ptrCast(@alignCast(userdata));

    sfetch.dowork();

    // Setup imgui
    sg.beginPass(.{ .swapchain = sglue.swapchain(), .action = state.pass_action });
    sdtx.origin(0.0, 2.0);
    sdtx.home();
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    state.ui(alloc);

    // Pipeline
    sg.applyPipeline(state.pipeline);
    if (state.model) |model| {
        var node_queue = std.ArrayList(Node).empty;
        if (state.scene_root_index) |root_idx| {
            const root = model.scene_trees[root_idx];
            node_queue.append(alloc, root.nodes[root.root_idx]) catch @panic("Failed to append node to queue");
        }
        while (node_queue.pop()) |node| {
            if (node.mesh) |mesh| {
                for (mesh.primitives) |prim| {
                    sg.applyBindings(prim.binding);
                    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&state.vsUniforms(&prim, node.accumulated_transform)));
                    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&state.fsUniforms(&prim)));
                    sg.draw(0, prim.object_count, 1);
                }
            }
            for (node.children) |child| {
                node_queue.append(alloc, child.*) catch {};
            }
        }
    }

    sgimgui.draw();
    simgui.render();
    sdtx.draw();

    sg.endPass();
    sg.commit();
}

export fn cleanup(userdata: ?*anyopaque) void {
    _ = userdata;
    sfetch.shutdown();
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

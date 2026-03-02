const builtin = @import("builtin");
const std = @import("std");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const simgui = sokol.imgui;
const sgimgui = sokol.sgimgui;

const ig = @import("cimgui");

const util = @import("util.zig");
const terrain = @import("terrain.zig");
const math = @import("math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

const shd = @import("terrain.glsl.zig");

const state = struct {
    var pass_action: sg.PassAction = .{};
    var pipelines: [2]sg.Pipeline = @splat(.{});
    var bind: sg.Bindings = .{};

    var vertices: ?[]terrain.Vertex = null;
    var indices: ?[]u16 = null;

    var mouse_down: bool = false;
};

export fn init() void {
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });
    simgui.setup(.{ .logger = .{ .func = slog.func } });
    sgimgui.setup(.{});
    const allocator = if (builtin.cpu.arch.isWasm()) std.heap.c_allocator else std.heap.smp_allocator;

    sdtx.setup(.{
        .fonts = init: {
            var f: [8]sdtx.FontDesc = @splat(.{});
            f[0] = sdtx.fontKc854();
            break :init f;
        },
        .logger = .{ .func = slog.func },
    });

    // Construct the grid mesh just so we can size the initial dynamic buffer
    state.vertices = terrain.vertices(allocator, 200);
    state.indices = terrain.indices(allocator, 200);
    const vertices_range = sg.asRange(state.vertices.?);
    const indices_range = sg.asRange(state.indices.?);
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{ .usage = .{ .dynamic_update = true, .vertex_buffer = true }, .size = vertices_range.size });
    state.bind.index_buffer = sg.makeBuffer(.{ .usage = .{ .dynamic_update = true, .index_buffer = true }, .size = indices_range.size });

    // create a small checker-board image and texture view
    state.bind.views[shd.VIEW_tex] = sg.makeView(.{
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

    state.bind.samplers[shd.SMP_smp] = sg.makeSampler(.{});

    state.pipelines[0] = terrain.cpuPipeline();
    state.pipelines[1] = terrain.gpuPipeline();

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = 0.0,
            .g = 0.0,
            .b = 0.0,
            .a = 1,
        },
    };
}

export fn frame() void {
    const allocator = if (builtin.cpu.arch.isWasm()) std.heap.c_allocator else std.heap.smp_allocator;
    const terrain_state = terrain.getState();

    allocator.free(state.vertices.?);
    allocator.free(state.indices.?);

    state.vertices = terrain.vertices(allocator, terrain_state.mesh_vertices);
    state.indices = terrain.indices(allocator, terrain_state.mesh_vertices);

    const vertices_range = sg.asRange(state.vertices.?);
    const indices_range = sg.asRange(state.indices.?);
    sg.updateBuffer(state.bind.vertex_buffers[0], vertices_range);
    sg.updateBuffer(state.bind.index_buffer, indices_range);

    sdtx.print("Reallocating {d} vertices\n", .{terrain_state.mesh_vertices});

    // Setup imgui
    sg.beginPass(.{ .swapchain = sglue.swapchain(), .action = state.pass_action });
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });
    if (ig.igBeginMainMenuBar()) {
        sgimgui.drawMenu("sokol-gfx");
        ig.igEndMainMenuBar();
    }
    terrain.ui();

    // Pipeline
    const selected_pipeline = state.pipelines[@intFromBool(terrain_state.render_gpu)];
    sg.applyPipeline(selected_pipeline);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&terrain.getVsParams()));
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&terrain.getFsParams()));

    // Draw
    sg.draw(0, terrain.getObjectCount(), 1);
    sdtx.draw();
    sgimgui.draw();
    simgui.render();

    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sgimgui.shutdown();
    sg.shutdown();
}

export fn event(e: [*c]const sapp.Event) callconv(.c) void {
    if (simgui.handleEvent(e.*)) {
        return;
    }
    const s = terrain.getState();
    switch (e.*.type) {
        .MOUSE_SCROLL => {
            s.camera_radius = @max(10.0, @min(300.0, s.camera_radius + e.*.scroll_y));
        },
        .MOUSE_DOWN => {
            state.mouse_down = true;
        },
        .MOUSE_UP => {
            state.mouse_down = false;
        },
        .MOUSE_MOVE => {
            if (state.mouse_down) {
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
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
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

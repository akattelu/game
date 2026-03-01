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
    var pipeline: sg.Pipeline = .{};
    var bind: sg.Bindings = .{};

    var terrain_state = terrain.state;

    var eye: Vec3 = .{ .x = 110.0, .y = 125.0, .z = 30.0 };
};

export fn init() void {
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });
    sgimgui.setup(.{});
    simgui.setup(.{ .logger = .{ .func = slog.func } });
    const allocator = if (builtin.cpu.arch.isWasm()) std.heap.c_allocator else std.heap.smp_allocator;

    sdtx.setup(.{
        .fonts = init: {
            var f: [8]sdtx.FontDesc = @splat(.{});
            f[0] = sdtx.fontKc854();
            break :init f;
        },
        .logger = .{ .func = slog.func },
    });

    const range = terrain.vertices(allocator);
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{ .usage = .{ .dynamic_update = true, .vertex_buffer = true }, .size = range.size });

    // cube index buffer
    state.bind.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = terrain.indices(allocator),
    });

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

    state.pipeline = sg.makePipeline(
        .{
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

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = 0.25,
            .g = 0.5,
            .b = 0.75,
            .a = 1,
        },
    };
}

export fn frame() void {
    const allocator = if (builtin.cpu.arch.isWasm()) std.heap.c_allocator else std.heap.smp_allocator;
    const terrain_state = terrain.getState();

    // Recreate terrain vertex buffer every frame
    // because the vertex count is a dynamic parameter
    const terrain_frame = terrain.vertices(allocator);
    sg.destroyBuffer(state.bind.vertex_buffers[0]);
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .usage = .{ .dynamic_update = true, .vertex_buffer = true },
        .size = terrain_frame.size,
    });
    sg.updateBuffer(state.bind.vertex_buffers[0], terrain_frame);

    sg.destroyBuffer(state.bind.index_buffer);
    state.bind.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = terrain.indices(allocator),
    });

    // Setup shader params
    const vs_params: shd.VsParams = .{
        .mvp = Mat4.mvp(state.eye, sapp.widthf(), sapp.heightf()),
    };
    const fs_params: shd.FsParams = .{
        .light_dir = Vec3.new(
            @cos(terrain_state.elevation_angle) * @sin(terrain_state.azimuth_angle),
            @sin(terrain_state.elevation_angle),
            @cos(terrain_state.elevation_angle) * @cos(terrain_state.azimuth_angle),
        ),
        .light_color = terrain_state.light_color,
        .use_texture = if (terrain_state.apply_texture) 1.0 else 0.0,
        .use_lighting = if (terrain_state.apply_lighting) 1.0 else 0.0,
        .ambient_intensity = terrain_state.ambient_intensity,
    };

    // Setup imgui
    sg.beginPass(.{ .swapchain = sglue.swapchain() });
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });
    terrain.ui();

    // Pipeline
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));

    // Draw
    sg.draw(0, terrain.getObjectCount(), 1);
    sdtx.draw();
    sgimgui.draw();
    simgui.render();

    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}

export fn event(e: [*c]const sapp.Event) callconv(.c) void {
    _ = simgui.handleEvent(e.*);
    switch (e.*.type) {
        .KEY_DOWN => {
            switch (e.*.key_code) {
                .LEFT => state.eye.y -= 0.8,
                .RIGHT => state.eye.y += 0.8,

                .UP => state.eye.z -= 0.8,
                .DOWN => state.eye.z += 0.8,

                .A => state.eye.x -= 0.8,
                .D => state.eye.x += 0.8,

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
    });
}

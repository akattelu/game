const std = @import("std");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;

const math = @import("math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

const shd = @import("cube.glsl.zig");

const state = struct {
    var rx: f32 = 0.0;
    var ry: f32 = 0.0;
    var pass_action: sg.PassAction = .{};
    var pipeline: sg.Pipeline = .{};
    var bind: sg.Bindings = .{};

    var eye: Vec3 = .{ .x = 0.0, .y = 1.5, .z = 5.0 };
};

const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };

export fn init() void {
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });

    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]Vertex{
            // zig fmt: off
            .{ .x = -1.0, .y = -1.0, .z = -1.0, .color = 0xFF0000FF, .u = 0,     .v = 0 },
            .{ .x =  1.0, .y = -1.0, .z = -1.0, .color = 0xFF0000FF, .u = 32767, .v = 0 },
            .{ .x =  1.0, .y =  1.0, .z = -1.0, .color = 0xFF0000FF, .u = 32767, .v = 32767 },
            .{ .x = -1.0, .y =  1.0, .z = -1.0, .color = 0xFF0000FF, .u = 0,     .v = 32767 },

            .{ .x = -1.0, .y = -1.0, .z =  1.0, .color = 0xFF00FF00, .u = 0,     .v = 0 },
            .{ .x =  1.0, .y = -1.0, .z =  1.0, .color = 0xFF00FF00, .u = 32767, .v = 0 },
            .{ .x =  1.0, .y =  1.0, .z =  1.0, .color = 0xFF00FF00, .u = 32767, .v = 32767 },
            .{ .x = -1.0, .y =  1.0, .z =  1.0, .color = 0xFF00FF00, .u = 0,     .v = 32767 },

            .{ .x = -1.0, .y = -1.0, .z = -1.0, .color = 0xFFFF0000, .u = 0,     .v = 0 },
            .{ .x = -1.0, .y =  1.0, .z = -1.0, .color = 0xFFFF0000, .u = 32767, .v = 0 },
            .{ .x = -1.0, .y =  1.0, .z =  1.0, .color = 0xFFFF0000, .u = 32767, .v = 32767 },
            .{ .x = -1.0, .y = -1.0, .z =  1.0, .color = 0xFFFF0000, .u = 0,     .v = 32767 },

            .{ .x =  1.0, .y = -1.0, .z = -1.0, .color = 0xFFFF007F, .u = 0,     .v = 0 },
            .{ .x =  1.0, .y =  1.0, .z = -1.0, .color = 0xFFFF007F, .u = 32767, .v = 0 },
            .{ .x =  1.0, .y =  1.0, .z =  1.0, .color = 0xFFFF007F, .u = 32767, .v = 32767 },
            .{ .x =  1.0, .y = -1.0, .z =  1.0, .color = 0xFFFF007F, .u = 0,     .v = 32767 },

            .{ .x = -1.0, .y = -1.0, .z = -1.0, .color = 0xFFFF7F00, .u = 0,     .v = 0 },
            .{ .x = -1.0, .y = -1.0, .z =  1.0, .color = 0xFFFF7F00, .u = 32767, .v = 0 },
            .{ .x =  1.0, .y = -1.0, .z =  1.0, .color = 0xFFFF7F00, .u = 32767, .v = 32767 },
            .{ .x =  1.0, .y = -1.0, .z = -1.0, .color = 0xFFFF7F00, .u = 0,     .v = 32767 },

            .{ .x = -1.0, .y =  1.0, .z = -1.0, .color = 0xFF007FFF, .u = 0,     .v = 0 },
            .{ .x = -1.0, .y =  1.0, .z =  1.0, .color = 0xFF007FFF, .u = 32767, .v = 0 },
            .{ .x =  1.0, .y =  1.0, .z =  1.0, .color = 0xFF007FFF, .u = 32767, .v = 32767 },
            .{ .x =  1.0, .y =  1.0, .z = -1.0, .color = 0xFF007FFF, .u = 0,     .v = 32767 },
            // zig fmt: on
        }),
    });


    // cube index buffer
    state.bind.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = sg.asRange(&[_]u16{
            0,  1,  2,  0,  2,  3,
            6,  5,  4,  7,  6,  4,
            8,  9,  10, 8,  10, 11,
            14, 13, 12, 15, 14, 12,
            16, 17, 18, 16, 18, 19,
            22, 21, 20, 23, 22, 20,
        }),
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

    state.pipeline = sg.makePipeline(
        .{
            .shader = sg.makeShader(shd.cubeShaderDesc(sg.queryBackend())),
            .layout = init: {
                var l = sg.VertexLayoutState{};
                l.attrs[shd.ATTR_cube_position].format = .FLOAT3;
                l.attrs[shd.ATTR_cube_color0].format = .UBYTE4N;
                l.attrs[shd.ATTR_cube_texcoord0].format = .SHORT2N;
                break :init l;
            },
            .index_type = .UINT16,
            .depth = .{
                .compare = .LESS_EQUAL,
                .write_enabled = true,
            },
            .cull_mode = .BACK,
        },
    );

    state.bind.samplers[shd.SMP_smp] = sg.makeSampler(.{});

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
    // const dt: f32 = @floatCast(sapp.frameDuration() * 60);
    // state.rx += 1.0 * dt;
    // state.ry += 2.0 * dt;
    const vs_params = computeVsParams(state.rx, state.ry);

    sg.beginPass(.{
        .swapchain = sglue.swapchain(),
    });
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 36, 1);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}

export fn event(e: [*c]const sapp.Event) callconv(.c) void{
    switch (e.*.type) {
        .KEY_DOWN => {
            switch (e.*.key_code) {
                .LEFT =>  {
                    state.eye.y -= 0.8;
                },
                .RIGHT => {
                    state.eye.y += 0.8;
                },

                .UP =>  {
                    state.eye.z -= 0.8;
                },
                .DOWN => {
                    state.eye.z += 0.8;
                },

                .A =>  {
                    state.eye.x -= 0.8;
                },
                .D=> {
                    state.eye.x += 0.8;
                },
                else => {
                    
                }
            }
        },
        else => {
            
        }
    }
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,

        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .window_title = "game",

        .sample_count = 4,

        .logger = .{ .func = slog.func },
    });
}

fn computeVsParams(rx: f32, ry: f32) shd.VsParams {
    const rxm = Mat4.rotate(rx, .{ .x = 1.0, .y = 0.0, .z = 0.0 });
    const rym = Mat4.rotate(ry, .{ .x = 0.0, .y = 1.0, .z = 0.0 });
    const model = Mat4.mul(rxm, rym);
    const aspect = sapp.widthf() / sapp.heightf();
    const proj = Mat4.persp(60.0, aspect, 0.01, 100.0);
    const view: Mat4 = Mat4.lookat(state.eye, Vec3.zero(), Vec3.up());

    return shd.VsParams{
        .mvp = Mat4.mul(Mat4.mul(proj, view), model),
    };
}

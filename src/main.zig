const std = @import("std");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = @import("sokol").debugtext;

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

    var eye: Vec3 = .{ .x = 0.0, .y = 5.0, .z = 5.0 };
};

const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };

fn mapRange(value: f32, in_min: f32, in_max: f32, out_min: f32, out_max: f32) f32 {
    return (value - in_min) / (in_max - in_min) * (out_max - out_min) + out_min;
}

fn rgbaToU32(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, b) << 16 | @as(u32, g) << 8 | r;
}

inline fn vertices(comptime n: comptime_int) sg.Range {
    var v: [n][n]Vertex = undefined;
    const nf: f32 = @floatFromInt(n);
    for (0..n) |i| {
        for (0..n) |j| {
            const r: u8 = @intFromFloat(mapRange(@floatFromInt(i), 0, n - 1, 0, 255));
            const g: u8 = @intFromFloat(mapRange(@floatFromInt(j), 0, n - 1, 0, 255));
            const b: u8 = 128;
            const ir: f32 = @as(f32, @floatFromInt(i)) / (nf - 1);
            _ = ir; // autofix
            const jr: f32 = @as(f32, @floatFromInt(j)) / (nf - 1);
            _ = jr; // autofix
            v[i][j] = .{
                .x = @as(f32, @floatFromInt(i)) - (nf / 2.0),
                .y = 0,
                .z = @as(f32, @floatFromInt(j)) - (nf / 2.0),
                .color = rgbaToU32(r, g, b, 255),
                .u = @intCast(@divTrunc(i, n)),
                .v = @intCast(@divTrunc(j, n)),
            };
        }
    }
    return sg.asRange(&v);
}

inline fn indices(comptime n: comptime_int) sg.Range {
    var idx: [(n - 1) * (n - 1) * 6]u16 = undefined;
    var count: usize = 0;
    for (0..n - 1) |iz| {
        for (0..n - 1) |ix| {
            const A: u16 = @intCast(iz * n + ix);
            const B: u16 = @intCast(iz * n + ix + 1);
            const C: u16 = @intCast((iz + 1) * n + ix);
            const D: u16 = @intCast((iz + 1) * n + ix + 1);

            idx[count + 0] = A;
            idx[count + 1] = C;
            idx[count + 2] = B;

            idx[count + 3] = B;
            idx[count + 4] = C;
            idx[count + 5] = D;

            count += 6;
        }
    }
    return sg.asRange(&idx);
}
export fn init() void {
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });

    sdtx.setup(.{
        .fonts = init: {
            var f: [8]sdtx.FontDesc = @splat(.{});
            f[0] = sdtx.fontKc854();
            break :init f;
        },
        .logger = .{ .func = slog.func },
    });

    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = vertices(3),
    });

    // cube index buffer
    state.bind.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = indices(3),
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
            .cull_mode = .NONE,
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
    const dt: f32 = @floatCast(sapp.frameDuration() * 60);
    // _ = dt; // autofix
    state.rx += 1.0 * dt;
    state.ry += 2.0 * dt;
    const vs_params = computeVsParams(state.rx, state.ry);

    sdtx.print("Hello '{s}'!\n", .{"world"});

    sg.beginPass(.{
        .swapchain = sglue.swapchain(),
    });
    sg.applyPipeline(state.pipeline);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 24, 1);
    sdtx.draw();
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}

export fn event(e: [*c]const sapp.Event) callconv(.c) void {
    switch (e.*.type) {
        .KEY_DOWN => {
            switch (e.*.key_code) {
                .LEFT => {
                    state.eye.y -= 0.8;
                },
                .RIGHT => {
                    state.eye.y += 0.8;
                },

                .UP => {
                    state.eye.z -= 0.8;
                },
                .DOWN => {
                    state.eye.z += 0.8;
                },

                .A => {
                    state.eye.x -= 0.8;
                },
                .D => {
                    state.eye.x += 0.8;
                },
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

        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .window_title = "game",

        .sample_count = 4,

        .logger = .{ .func = slog.func },
    });
}

fn computeVsParams(rx: f32, ry: f32) shd.VsParams {
    _ = rx; // autofix
    _ = ry; // autofix
    // const rxm = Mat4.rotate(rx, .{ .x = 1.0, .y = 0.0, .z = 0.0 });
    // const rym = Mat4.rotate(ry, .{ .x = 0.0, .y = 1.0, .z = 0.0 });
    // const model = Mat4.mul(rxm, rym);
    const model = Mat4.identity();
    const aspect = sapp.widthf() / sapp.heightf();
    const proj = Mat4.persp(60.0, aspect, 0.01, 100.0);
    const view: Mat4 = Mat4.lookat(state.eye, Vec3.zero(), Vec3.up());

    return shd.VsParams{
        .mvp = Mat4.mul(Mat4.mul(proj, view), model),
    };
}

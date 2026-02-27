const sg = @import("sokol").gfx;
const util = @import("util.zig");

pub const Vertex = extern struct { x: f32, y: f32, z: f32, color: u32, u: i16, v: i16 };
pub const state = struct {};

pub inline fn vertices(comptime n: comptime_int) sg.Range {
    var v: [n][n]Vertex = undefined;
    const nf: f32 = @floatFromInt(n);
    for (0..n) |i| {
        for (0..n) |j| {
            const r: u8 = @intFromFloat(util.mapRange(@floatFromInt(i), 0, n - 1, 0, 255));
            const g: u8 = @intFromFloat(util.mapRange(@floatFromInt(j), 0, n - 1, 0, 255));
            const b: u8 = 128;

            // const h: f32 = @floatCast(util.mapRange(@floatFromInt(i * j), 0.0, @floatCast(n * n), 0.0, 10.0));
            const h: f32 = util.sampleNoise(@floatFromInt(i), @floatFromInt(j));
            v[i][j] = .{
                .x = @as(f32, @floatFromInt(i)) - (nf / 2.0),
                .y = if (i == 0 or j == 0 or i == (n - 1) or j == (n - 1)) 0 else h,
                // .y = 0.0,
                .z = @as(f32, @floatFromInt(j)) - (nf / 2.0),
                .color = util.rgbaToU32(r, g, b, 255),
                .u = @intCast(@divTrunc(i, n)),
                .v = @intCast(@divTrunc(j, n)),
            };
        }
    }
    return sg.asRange(&v);
}

pub inline fn indices(comptime n: comptime_int) sg.Range {
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

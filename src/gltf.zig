const std = @import("std");
const Gltf = @import("zgltf").Gltf;
const terrain = @import("terrain.zig");
const math = @import("math.zig");
const util = @import("util.zig");
const Vec3 = math.Vec3;

const allocator = std.heap.page_allocator;
const print = std.debug.print;

pub fn printFile(path: []const u8) !void {
    const buffer = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        512_000_000,
        null,
        .@"4",
        null,
    );
    defer allocator.free(buffer);

    var vertices: std.ArrayList(terrain.Vertex) = .empty;
    var indices: std.ArrayList(u16) = .empty;

    var gltf = Gltf.init(allocator);
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
                            try vertices.append(allocator, .{
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
                        print("Primitive color: {any}\n", .{color});
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
                    try indices.append(allocator, i[0]);
                }
            }
            print("\n", .{});
        }
    }

    // print("Vertex Items: {any}\n", .{vertices.items});
    // print("Indices items: {any}\n", .{indices.items});
}

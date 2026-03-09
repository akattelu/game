const std = @import("std");
const print = std.debug.print;
const sprint = std.fmt.allocPrint;

const sokol = @import("sokol");
const sg = sokol.gfx;

const Gltf = @import("zgltf").Gltf;
const zigimg = @import("zigimg");

const math = @import("math.zig");
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const util = @import("util.zig");
const shd = @import("../shaders/gltf.glsl.zig");

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    color: u32,
    u: i16,
    v: i16,
    normal: Vec3,
    tangent: Vec4,
};

pub const GltfModel = struct {
    gltf: Gltf,
    meshes: []Mesh,

    pub fn deinit(self: *GltfModel) void {
        for (self.meshes) |*mesh| {
            mesh.deinit();
        }
    }
    pub fn initMeshes(self: *GltfModel, alloc: std.mem.Allocator) !void {
        var primitives: std.ArrayList(Primitive) = .empty;
        var meshes: std.ArrayList(Mesh) = .empty;

        for (self.gltf.data.meshes) |gltf_mesh| {
            for (gltf_mesh.primitives) |gltf_prim| {
                var prim: Primitive = .init(alloc);
                try prim.loadVertices(&gltf_prim, &self.gltf);
                try prim.loadIndices(&gltf_prim, &self.gltf);
                try prim.loadMaterial(&gltf_prim, &self.gltf);
                try prim.loadSamplers();

                try primitives.append(alloc, prim);
            }

            const mesh_primitives = try primitives.toOwnedSlice(alloc);
            const mesh: Mesh = .{ .name = gltf_mesh.name, .primitives = mesh_primitives };
            try meshes.append(alloc, mesh);
        }
        self.meshes = try meshes.toOwnedSlice(alloc);
    }
};
pub const Mesh = struct {
    name: ?[]const u8,
    primitives: []Primitive,

    pub fn deinit(self: *Mesh) void {
        for (self.primitives) |*prim| {
            prim.deinit();
        }
    }
};

pub const Primitive = struct {
    arena: std.heap.ArenaAllocator,
    binding: sg.Bindings = .{},
    object_count: u32 = 0,
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    has_normal_map_data: bool = false,
    has_metallic_roughness_texture: bool = false,
    //  Need to keep track of these so that we can destroy them later
    images: std.ArrayList(sg.Image) = .empty,

    pub fn init(allocator: std.mem.Allocator) Primitive {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return Primitive{
            .arena = arena,
        };
    }

    pub fn deinit(self: *Primitive) void {
        // GPU
        for (self.binding.vertex_buffers) |buf| {
            sg.destroyBuffer(buf);
        }
        sg.destroyBuffer(self.binding.index_buffer);
        for (self.binding.views) |view| {
            sg.destroyView(view);
        }
        for (self.binding.samplers) |smp| {
            sg.destroySampler(smp);
        }
        for (self.images.items) |img| {
            sg.destroyImage(img);
        }
        self.images.deinit(self.arena.allocator());

        // CPU
        self.arena.deinit();
    }

    pub fn loadVertices(self: *Primitive, gltf_prim: *const Gltf.Primitive, gltf: *Gltf) !void {
        const alloc = self.arena.allocator();
        var vertices: std.ArrayList(Vertex) = .empty;
        for (gltf_prim.attributes) |attr| {
            switch (attr) {
                .position => |pos| {
                    const accessor = gltf.data.accessors[pos];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
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
                    }
                },
                .normal => |normal| {
                    const accessor = gltf.data.accessors[normal];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                    var i: u32 = 0;
                    while (it.next()) |n| : (i += 1) {
                        vertices.items[i].normal = Vec3.new(n[0], n[1], n[2]);
                    }
                },
                .color => |color| {
                    const accessor = gltf.data.accessors[color];
                    var it = accessor.iterator(u32, gltf, gltf.glb_binary.?);
                    var i: u32 = 0;
                    while (it.next()) |n| : (i += 1) {
                        vertices.items[i].color = n[0];
                    }
                },
                .tangent => |tangent| {
                    const accessor = gltf.data.accessors[tangent];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                    var i: u32 = 0;
                    while (it.next()) |n| : (i += 1) {
                        vertices.items[i].tangent = Vec4.new(n[0], n[1], n[2], n[3]);
                    }
                    self.has_normal_map_data = true;
                },
                .texcoord => |texcoord| {
                    const accessor = gltf.data.accessors[texcoord];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                    var i: u32 = 0;
                    while (it.next()) |uv| : (i += 1) {
                        vertices.items[i].u = @intFromFloat(@round(std.math.clamp(uv[0], -1.0, 1.0) * 32767.0));
                        vertices.items[i].v = @intFromFloat(@round(std.math.clamp(uv[1], -1.0, 1.0) * 32767.0));
                    }
                },
                else => {},
            }
        }
        const owned_vertices = try vertices.toOwnedSlice(alloc);

        // Load vertex buffer with all info from parsing vertex attributes
        self.binding.vertex_buffers[0] = sg.makeBuffer(.{
            .label = "Primitive Vertex Buffer",
            .usage = .{ .vertex_buffer = true },
            .data = sg.asRange(owned_vertices),
        });
    }

    pub fn loadIndices(self: *Primitive, gltf_prim: *const Gltf.Primitive, gltf: *Gltf) !void {
        const alloc = self.arena.allocator();
        var indices = std.ArrayList(u16).empty;
        // Read and load indices
        if (gltf_prim.indices) |prim_indices| {
            const accessor = gltf.data.accessors[prim_indices];
            if (accessor.component_type == .unsigned_short) {
                var it = accessor.iterator(u16, gltf, gltf.glb_binary.?);
                while (it.next()) |i| {
                    try indices.append(alloc, i[0]);
                }
            }

            const owned_indices = try indices.toOwnedSlice(alloc);
            self.binding.index_buffer = sg.makeBuffer(.{
                .label = "Primitive Index Buffer",
                .usage = .{ .index_buffer = true },
                .data = sg.asRange(owned_indices),
            });
            self.object_count = @intCast(owned_indices.len);
        }
    }

    pub fn loadSamplers(self: *Primitive) !void {
        self.binding.samplers[shd.SMP_smp] = sg.makeSampler(.{});
        self.binding.samplers[shd.SMP_normal_smp] = sg.makeSampler(.{});
        self.binding.samplers[shd.SMP_mr_smp] = sg.makeSampler(.{});
    }

    pub fn loadMaterial(self: *Primitive, gltf_prim: *const Gltf.Primitive, gltf: *Gltf) !void {
        const alloc = self.arena.allocator();
        if (gltf_prim.material) |mat_idx| {
            const material = gltf.data.materials[mat_idx];
            const material_name = material.name orelse "(unknown-material-name)";
            self.metallic_factor = material.metallic_roughness.metallic_factor;
            self.roughness_factor = material.metallic_roughness.roughness_factor;

            // Load normal map texture image
            var normal_map_texture_image: sg.Image = .{};
            if (material.normal_texture) |tex| {
                const encoded_bytes = gltf.data.images[gltf.data.textures[tex.index].source.?].data.?;
                normal_map_texture_image = try imageFromBuffer(alloc, (try sprint(alloc, "{s} Normal Map Texture", .{material_name})), encoded_bytes);
            } else {
                normal_map_texture_image = dummyImage("Dummy base normal map texture image", 0xFFFF8080);
                self.has_normal_map_data = false;
            }
            self.binding.views[shd.VIEW_normal_tex] = sg.makeView(.{
                .label = (try sprint(alloc, "{s} Normal Map Texture", .{material_name})).ptr,
                .texture = .{ .image = normal_map_texture_image },
            });

            // Load base color texture image
            var base_color_texture_image: sg.Image = .{};
            if (material.metallic_roughness.base_color_texture) |tex| {
                const encoded_bytes = gltf.data.images[gltf.data.textures[tex.index].source.?].data.?;
                base_color_texture_image = try imageFromBuffer(alloc, (try sprint(alloc, "{s} Base Color Texture", .{material_name})), encoded_bytes);
            } else {
                base_color_texture_image = dummyImage("Dummy base color texture image", 0xFFFFFFFF);
            }
            self.binding.views[shd.VIEW_tex] = sg.makeView(.{
                .label = (try sprint(alloc, "{s} Metallic Roughness Base Texture ", .{material_name})).ptr,
                .texture = .{ .image = base_color_texture_image },
            });

            // Load metallic roughness texture image
            var metallic_roughness_texture_image: sg.Image = .{};
            if (material.metallic_roughness.metallic_roughness_texture) |tex| {
                const encoded_bytes = gltf.data.images[gltf.data.textures[tex.index].source.?].data.?;
                metallic_roughness_texture_image = try imageFromBuffer(alloc, (try sprint(alloc, "{s} Metallic Roughness Texture", .{material_name})), encoded_bytes);
                self.has_metallic_roughness_texture = true;
            } else {
                metallic_roughness_texture_image = dummyImage("Dummy MR texture image", 0xFFFFFFFF);
            }
            self.binding.views[shd.VIEW_mr_tex] = sg.makeView(.{
                .label = (try sprint(alloc, "{s} Metallic Roughness Texture", .{material_name})).ptr,
                .texture = .{ .image = metallic_roughness_texture_image },
            });

            // Store for destruction later
            try self.images.append(alloc, base_color_texture_image);
            try self.images.append(alloc, normal_map_texture_image);
            try self.images.append(alloc, metallic_roughness_texture_image);
        }
    }
};

fn imageFromBuffer(alloc: std.mem.Allocator, label: []const u8, buffer: []const u8) !sg.Image {
    var img = try zigimg.Image.fromMemory(alloc, buffer);
    const w: i32 = @intCast(img.width);
    const h: i32 = @intCast(img.height);
    try img.convert(alloc, .rgba32);
    const img_pixels = img.rawBytes();
    return sg.makeImage(.{
        .label = label.ptr,
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

fn dummyImage(label: []const u8, pixel_value: u32) sg.Image {
    return sg.makeImage(.{
        .label = label.ptr,
        .width = 1,
        .height = 1,
        .pixel_format = .RGBA8,
        .data = init: {
            var data = sg.ImageData{};
            data.mip_levels[0] = sg.asRange(&[1]u32{pixel_value});
            break :init data;
        },
    });
}

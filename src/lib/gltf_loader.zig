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
    joint: Vec4,
    weight: Vec4,
};

pub const Node = struct {
    children: []Node,
    mesh: ?Mesh,
    transform_trs: Mat4,

    pub fn deinit(self: *Node) void {
        for (self.children) |*child| {
            child.deinit();
        }
        if (self.mesh) |*mesh| {
            mesh.deinit();
        }
    }
};

pub const GltfModel = struct {
    gltf: Gltf,
    scene_roots: []Node = std.ArrayList(Node).empty.items,

    pub fn init(alloc: std.mem.Allocator, buffer: []align(4) const u8) !GltfModel {
        var gltf = Gltf.init(alloc);
        try gltf.parse(buffer);
        var model: GltfModel = .{ .gltf = gltf };
        try model.initTree(alloc);
        return model;
    }

    pub fn deinit(self: *GltfModel) void {
        for (self.scene_roots) |*root| {
            root.deinit();
        }
    }

    pub fn loadMesh(self: *GltfModel, alloc: std.mem.Allocator, mesh_idx: usize) !Mesh {
        const gltf_mesh = self.gltf.data.meshes[mesh_idx];
        var primitives: std.ArrayList(Primitive) = .empty;
        for (gltf_mesh.primitives) |*gltf_prim| {
            var prim: Primitive = .init(alloc);
            try prim.loadVertices(gltf_prim, &self.gltf);
            try prim.loadIndices(gltf_prim, &self.gltf);
            try prim.loadMaterial(gltf_prim, &self.gltf);
            try prim.loadSamplers();
            try primitives.append(alloc, prim);
        }
        const mesh: Mesh = .{
            .name = gltf_mesh.name,
            .primitives = try primitives.toOwnedSlice(alloc),
        };
        return mesh;
    }

    fn initNode(self: *GltfModel, alloc: std.mem.Allocator, node_idx: usize, trs: Mat4) !Node {
        const gltf_node: *Gltf.Node = &self.gltf.data.nodes[node_idx];
        var children: std.ArrayList(Node) = .empty;
        var mesh: ?Mesh = null;
        var transform_trs = Mat4.identity();

        // Apply local transform
        if (gltf_node.matrix) |matrix| {
            transform_trs = .fromArray(matrix);
        } else {
            transform_trs = Mat4.fromTRS(gltf_node.translation, gltf_node.rotation, gltf_node.scale);
        }

        // Apply mesh
        if (gltf_node.mesh) |mesh_idx| {
            mesh = try self.loadMesh(alloc, mesh_idx);
        }

        const world = Mat4.mul(transform_trs, trs);
        // Recursively initialize children
        for (gltf_node.children) |child_idx| {
            try children.append(alloc, try self.initNode(alloc, child_idx, world));
        }

        return Node{
            .children = try children.toOwnedSlice(alloc),
            .mesh = mesh,
            .transform_trs = world,
        };
    }

    pub fn initTree(self: *GltfModel, alloc: std.mem.Allocator) !void {
        const scene = self.gltf.data.scenes[self.gltf.data.scene orelse 0];

        var roots: std.ArrayList(Node) = .empty;
        if (scene.nodes) |nodes| {
            for (nodes) |node_idx| {
                try roots.append(alloc, try self.initNode(alloc, node_idx, Mat4.identity()));
            }
        }
        self.scene_roots = try roots.toOwnedSlice(alloc);
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
                            .joint = Vec4.new(0, 0, 0, 0),
                            .weight = Vec4.new(0, 0, 0, 0),
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
                .joints => |joints| {
                    // for now for joints just print the component type
                    const accessor = gltf.data.accessors[joints];
                    const component_type = accessor.component_type;
                    print("Joints component type: {s}\n", .{@tagName(component_type)});
                },
                .weights => |weights| {
                    // for now for weights just print the component type
                    const accessor = gltf.data.accessors[weights];
                    const component_type = accessor.component_type;
                    print("Weights component type: {s}\n", .{@tagName(component_type)});
                },
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

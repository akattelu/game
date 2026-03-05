const std = @import("std");
const sokol = @import("sokol");
const cimgui = @import("cimgui");
const ig = @import("cimgui");
const print = std.debug.print;
const sprint = std.fmt.allocPrint;

const WebGraphicsMode = enum { webgl, webgpu, none };
const AddDependenciesOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mode: WebGraphicsMode,
};
const Dependencies = struct {
    dep_sokol: *std.Build.Dependency,
    dep_cimgui: *std.Build.Dependency,
    dep_shdc: *std.Build.Dependency,
    dep_zgltf: *std.Build.Dependency,
};
const SokolTargetMode = enum { webgpu, webgl, native };
const SokolTarget = union(SokolTargetMode) {
    webgpu: void,
    webgl: void,
    native: std.Target.Query,
};
const BuildVariant = struct {
    target: SokolTarget,
    optimize: std.builtin.OptimizeMode,
    /// This is like `terrain` and will be expanded to `src/{root_app_name}.zig`
    /// It will also be used for downstream names like executables or steps
    root_app_name: []const u8,
};

pub fn build(b: *std.Build) !void {
    const optimize: std.builtin.OptimizeMode = switch (b.release_mode) {
        .off => .Debug,
        .fast => .ReleaseFast,
        .small => .ReleaseSmall,
        .safe => .ReleaseSafe,
        else => unreachable,
    };
    const variants: []const BuildVariant = &.{
        .{
            .optimize = optimize,
            .target = .webgpu,
            .root_app_name = "terrain_cpu",
        },
        .{
            .optimize = optimize,
            .target = .webgl,
            .root_app_name = "terrain_cpu",
        },
        .{
            .optimize = optimize,
            .target = .{ .native = .{} },
            .root_app_name = "terrain_cpu",
        },
        .{
            .optimize = optimize,
            .target = .{ .native = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
            .root_app_name = "terrain_cpu",
        },
        .{
            .optimize = optimize,
            .target = .webgpu,
            .root_app_name = "terrain_gpu",
        },
        .{
            .optimize = optimize,
            .target = .webgl,
            .root_app_name = "terrain_gpu",
        },
        .{
            .optimize = optimize,
            .target = .{ .native = .{} },
            .root_app_name = "terrain_gpu",
        },
        .{
            .optimize = optimize,
            .target = .{ .native = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
            .root_app_name = "terrain_gpu",
        },
        .{
            .optimize = optimize,
            .target = .{ .native = .{} },
            .root_app_name = "gltf",
        },
    };
    for (variants) |variant| {
        try buildFor(b, variant);
    }
}

fn addDependencies(b: *std.Build, options: AddDependenciesOptions) !Dependencies {
    const target = options.target;
    const optimize = options.optimize;
    const web_graphics = options.mode;

    // Sokol
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
        .with_tracing = true,
        .wgpu = web_graphics == .webgpu,
    });

    // ImGUI
    const cimgui_config = cimgui.getConfig(false);
    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_config.include_dir));

    // Sokol SHDC
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});

    // zgltf
    const dep_zgltf = b.dependency("zgltf", .{});

    return .{
        .dep_sokol = dep_sokol,
        .dep_cimgui = dep_cimgui,
        .dep_shdc = dep_shdc,
        .dep_zgltf = dep_zgltf,
    };
}

fn buildWeb(b: *std.Build, root_mod: *std.Build.Module, deps: Dependencies, variant: BuildVariant, add_run_step: bool) !*std.Build.Step {
    const lib_name = try sprint(b.allocator, "{s}_{s}", .{ variant.root_app_name, @tagName(std.meta.activeTag(variant.target)) });
    const lib = b.addLibrary(.{
        .name = lib_name,
        .root_module = root_mod,
    });

    // create a build step which invokes the Emscripten linker
    const emsdk = deps.dep_sokol.builder.dependency("emsdk", .{});
    const emsdk_incl_path = emsdk.path("upstream/emscripten/cache/sysroot/include");
    deps.dep_cimgui.artifact("cimgui_clib").root_module.addSystemIncludePath(emsdk_incl_path);
    // all C libraries need to depend on the sokol library, when building for
    // WASM this makes sure that the Emscripten SDK has been setup before
    // C compilation is attempted (since the sokol C library depends on the
    // Emscripten SDK setup step)
    deps.dep_cimgui.artifact("cimgui_clib").step.dependOn(&deps.dep_sokol.artifact("sokol_clib").step);
    const t = std.meta.activeTag(variant.target);
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 }),
        .optimize = variant.optimize,
        .emsdk = emsdk,
        .use_webgl2 = t == .webgl,
        .use_webgpu = t == .webgpu,
        .use_emmalloc = true,
        .use_filesystem = false,
        .extra_args = &.{
            "-sSTACK_SIZE=2MB",
            "-sINITIAL_MEMORY=6MB",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sASSERTIONS",
        },

        .shell_file_path = deps.dep_sokol.path("src/sokol/web/shell.html"),
    });
    if (add_run_step) {
        const run = sokol.emRunStep(b, .{ .name = lib_name, .emsdk = emsdk });
        run.step.dependOn(&link_step.step);
        const desc = try sprint(b.allocator, "Run game for {s}", .{@tagName(t)});
        b.step(lib_name, desc).dependOn(&run.step);
    }
    return &link_step.step;
}

fn compileShaders(b: *std.Build, dep_shdc: *std.Build.Dependency) !*std.Build.Step {
    const shdc_step = try sokol.shdc.createSourceFile(b, .{
        .shdc_dep = dep_shdc,
        .input = "src/shaders/terrain.glsl",
        .output = "src/shaders/terrain.glsl.zig",
        .slang = .{
            .metal_macos = true,
            .spirv_vk = true,
            .wgsl = true,
            .glsl430 = true,
            .glsl300es = true,
            .hlsl5 = true,
        },
    });

    return shdc_step;
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    print(format, args);
    std.process.exit(1);
}

fn buildFor(b: *std.Build, variant: BuildVariant) !void {
    const root_file_name = try sprint(b.allocator, "src/{s}.zig", .{variant.root_app_name});
    switch (variant.target) {
        .native => |query| {
            const t = b.resolveTargetQuery(query);
            const deps = try addDependencies(b, .{ .optimize = variant.optimize, .target = t, .mode = .none });
            const root_mod = b.createModule(.{
                .root_source_file = b.path(root_file_name),
                .target = t,
                .optimize = variant.optimize,
                .imports = &.{
                    .{ .name = "sokol", .module = deps.dep_sokol.module("sokol") },
                    .{ .name = "cimgui", .module = deps.dep_cimgui.module("cimgui") },
                    .{ .name = "zgltf", .module = deps.dep_zgltf.module("zgltf") },
                },
            });
            const shaders = try compileShaders(b, deps.dep_shdc);
            const name = try sprint(b.allocator, "{s}_{s}", .{ variant.root_app_name, @tagName(t.result.os.tag) });
            const exe = b.addExecutable(.{
                .name = name,
                .root_module = root_mod,
            });

            const exe_install = b.addInstallArtifact(exe, .{});

            // Setup run cmd
            if (t.result.os.tag == b.graph.host.result.os.tag) {
                // Setup run step only for native
                const run_desc = try sprint(b.allocator, "Run the {s} app natively", .{variant.root_app_name});
                const run_step = b.step(variant.root_app_name, run_desc);
                const run_cmd = b.addRunArtifact(exe);
                if (b.args) |args| {
                    run_cmd.addArgs(args);
                }
                run_step.dependOn(&run_cmd.step);
                run_cmd.step.dependOn(&exe_install.step);

                // Setup test step once only for native
                const test_name = try sprint(b.allocator, "{s}_tests", .{variant.root_app_name});
                const test_step = b.step(test_name, "Run tests");
                const exe_tests = b.addTest(.{ .name = test_name, .root_module = exe.root_module });
                const run_exe_tests = b.addRunArtifact(exe_tests);
                const tests_install = b.addInstallArtifact(exe_tests, .{});
                b.getInstallStep().dependOn(&tests_install.step);
                run_exe_tests.step.dependOn(&tests_install.step);
                test_step.dependOn(&run_exe_tests.step);
            }

            b.getInstallStep().dependOn(&exe_install.step);
            exe.step.dependOn(shaders);
        },
        else => { // WebGL or WebGPU
            const deps = try addDependencies(b, .{
                .target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 }),
                .optimize = variant.optimize,
                .mode = if (variant.target == .webgpu) .webgpu else .webgl,
            });
            const shaders = try compileShaders(b, deps.dep_shdc);
            const root_mod = b.createModule(.{
                .root_source_file = b.path(root_file_name),
                .target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 }),
                .optimize = variant.optimize,
                .imports = &.{
                    .{ .name = "sokol", .module = deps.dep_sokol.module("sokol") },
                    .{ .name = "cimgui", .module = deps.dep_cimgui.module("cimgui") },
                    .{ .name = "zgltf", .module = deps.dep_zgltf.module("zgltf") },
                },
            });
            const web_artifacts = try buildWeb(b, root_mod, deps, variant, true);
            web_artifacts.dependOn(shaders);
            b.getInstallStep().dependOn(web_artifacts);
        },
    }
}

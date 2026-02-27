const std = @import("std");
const sokol = @import("sokol");
const cimgui = @import("cimgui");
const ig = @import("cimgui");

const Options = struct {
    dep_sokol: *std.Build.Dependency,
    dep_cimgui: *std.Build.Dependency,

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    root_mod: *std.Build.Module,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
        .with_tracing = true,
    });

    const cimgui_config = cimgui.getConfig(false);
    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_config.include_dir));

    // extract shdc dependency from sokol dependency
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});

    // call shdc.createSourceFile() helper function, this returns a `!*Build.Step`:
    const shdc_step = try sokol.shdc.createSourceFile(b, .{
        .shdc_dep = dep_shdc,
        .input = "src/terrain.glsl",
        .output = "src/terrain.glsl.zig",
        .slang = .{
            .metal_macos = true,
            .spirv_vk = true,
            .wgsl = true,
            .glsl430 = true,
            .glsl300es = true,
            .hlsl5 = true,
        },
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
        },
    });
    if (!target.result.cpu.arch.isWasm()) {
        const exe = buildNative(b, .{
            .dep_sokol = dep_sokol,
            .dep_cimgui = dep_cimgui,
            .target = target,
            .optimize = optimize,
            .root_mod = root_mod,
        });
        // add the shader compilation step as dependency to the build step
        // which requires the generated Zig source file
        exe.step.dependOn(shdc_step);
    } else {
        const lib = try buildWeb(b, .{
            .dep_sokol = dep_sokol,
            .dep_cimgui = dep_cimgui,
            .target = target,
            .optimize = optimize,
            .root_mod = root_mod,
        });
        lib.step.dependOn(shdc_step);
    }
}

fn buildNative(b: *std.Build, options: Options) *std.Build.Step.Compile {
    const root_mod = options.root_mod;
    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = root_mod,
    });

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    b.installArtifact(exe);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    return exe;
}

fn buildWeb(b: *std.Build, options: Options) !*std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "game",
        .root_module = options.root_mod,
    });

    // create a build step which invokes the Emscripten linker
    const emsdk = options.dep_sokol.builder.dependency("emsdk", .{});
    const emsdk_incl_path = emsdk.path("upstream/emscripten/cache/sysroot/include");
    options.dep_cimgui.artifact("cimgui_clib").root_module.addSystemIncludePath(emsdk_incl_path);
    // all C libraries need to depend on the sokol library, when building for
    // WASM this makes sure that the Emscripten SDK has been setup before
    // C compilation is attempted (since the sokol C library depends on the
    // Emscripten SDK setup step)
    options.dep_cimgui.artifact("cimgui_clib").step.dependOn(&options.dep_sokol.artifact("sokol_clib").step);
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = options.target,
        .optimize = options.optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_webgpu = false,
        .use_emmalloc = true,
        .use_filesystem = false,
        // .shell_file_path = null,
        .extra_args = &.{
            "-sSTACK_SIZE=512KB",
            "-sINITIAL_MEMORY=64MB",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sASSERTIONS",
        },

        .shell_file_path = options.dep_sokol.path("src/sokol/web/shell.html"),
    });
    // attach Emscripten linker output to default install step
    b.getInstallStep().dependOn(&link_step.step);
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "game", .emsdk = emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run game").dependOn(&run.step);
    return lib;
}

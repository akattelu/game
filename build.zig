const std = @import("std");
const sokol = @import("sokol");
const cimgui = @import("cimgui");
const ig = @import("cimgui");
const print = std.debug.print;

const WebGraphicsMode = enum { webgl, webgpu, none };
const Options = struct {
    dep_sokol: *std.Build.Dependency,
    dep_cimgui: *std.Build.Dependency,
    dep_shdc: *std.Build.Dependency,

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    root_mod: *std.Build.Module,
};
const DepsOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mode: WebGraphicsMode,
    root_mod_filename: []const u8,
};

pub fn build(b: *std.Build) !void {
    const release = b.option(bool, "release", "Run a full release build across all targets") orelse false;
    const web = b.option(bool, "web", "Build for web. Defaults to using webgpu.") orelse false;
    if (web and release) _ = fatal("Web option is a no-op when running build in release mode\n\n", .{});

    switch (release) {
        true => {
            print("Running in release build mode\n", .{});
            const native_targets: []const std.Target.Query = &.{
                .{},
                .{ .cpu_arch = .x86_64, .os_tag = .windows },
            };
            for (native_targets) |target| {
                const options = setupDeps(b, .{
                    .target = b.resolveTargetQuery(target),
                    .optimize = .ReleaseSmall,
                    .mode = .none,
                    .root_mod_filename = "src/terrain_cpu.zig",
                });
                const shaders = try compileShaders(b, options);

                const exe = try buildNative(b, options);
                b.installArtifact(exe);
                exe.step.dependOn(shaders);
            }
            { // Web
                for ([_]WebGraphicsMode{ .webgl, .webgpu }) |mode| {
                    const options = setupDeps(b, .{
                        .target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 }),
                        .optimize = .ReleaseSafe,
                        .mode = mode,
                        .root_mod_filename = "src/terrain_cpu.zig",
                    });
                    const shaders = try compileShaders(b, options);
                    const web_artifacts = try buildWeb(b, options, mode, false);
                    web_artifacts.dependOn(shaders);
                    b.getInstallStep().dependOn(web_artifacts);
                }
            }
        },
        false => {
            switch (web) {
                true => {
                    print("Running in web build mode\n", .{});
                    const options = setupDeps(b, .{
                        .target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 }),
                        .optimize = .ReleaseFast,
                        .mode = .webgpu,
                        .root_mod_filename = "src/terrain_cpu.zig",
                    });
                    const shaders = try compileShaders(b, options);
                    const web_artifacts = try buildWeb(b, options, .webgpu, true);
                    web_artifacts.dependOn(shaders);
                    b.getInstallStep().dependOn(web_artifacts);
                },
                false => {
                    print("Running in standard build mode\n", .{});
                    const target = b.standardTargetOptions(.{});
                    const options = setupDeps(b, .{
                        .optimize = b.standardOptimizeOption(.{}),
                        .target = target,
                        .root_mod_filename = "src/terrain_cpu.zig",
                        .mode = .none,
                    });
                    const shaders = try compileShaders(b, options);
                    const exe = try buildNative(b, options);

                    const run_step = b.step("run", "Run the app");
                    const test_step = b.step("test", "Run tests");

                    const exe_tests = b.addTest(.{ .name = "game-tests", .root_module = exe.root_module });
                    const run_exe_tests = b.addRunArtifact(exe_tests);

                    const run_cmd = b.addRunArtifact(exe);
                    if (b.args) |args| {
                        run_cmd.addArgs(args);
                    }

                    const exe_install = b.addInstallArtifact(exe, .{ .dest_sub_path = "game" });
                    const tests_install = b.addInstallArtifact(exe_tests, .{});

                    // exe_install.step.dependOn(b.getInstallStep());
                    b.getInstallStep().dependOn(&exe_install.step);
                    b.getInstallStep().dependOn(&tests_install.step);
                    exe.step.dependOn(shaders);
                    run_step.dependOn(&run_cmd.step);
                    run_exe_tests.step.dependOn(&tests_install.step);
                    run_cmd.step.dependOn(&exe_install.step);
                    test_step.dependOn(&run_exe_tests.step);
                },
            }
        },
    }
}

fn buildNative(b: *std.Build, options: Options) !*std.Build.Step.Compile {
    const root_mod = options.root_mod;
    const triple = try options.target.result.linuxTriple(b.allocator);
    const name = try std.fmt.allocPrint(b.allocator, "game-{s}", .{triple});
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_mod,
    });

    return exe;
}

fn buildWeb(b: *std.Build, options: Options, web_graphics: WebGraphicsMode, add_run_step: bool) !*std.Build.Step {
    const name = try std.fmt.allocPrint(b.allocator, "game-{s}", .{@tagName(web_graphics)});
    const lib = b.addLibrary(.{
        .name = name,
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
        .use_webgl2 = web_graphics == .webgl,
        .use_webgpu = web_graphics == .webgpu,
        .use_emmalloc = true,
        .use_filesystem = false,
        .extra_args = &.{
            "-sSTACK_SIZE=2MB",
            "-sINITIAL_MEMORY=6MB",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sASSERTIONS",
        },

        .shell_file_path = options.dep_sokol.path("src/sokol/web/shell.html"),
    });
    if (add_run_step) {
        const run = sokol.emRunStep(b, .{ .name = name, .emsdk = emsdk });
        run.step.dependOn(&link_step.step);
        b.step("run", "Run game").dependOn(&run.step);
    }
    return &link_step.step;
}

fn setupDeps(b: *std.Build, options: DepsOptions) Options {
    const target = options.target;
    const optimize = options.optimize;
    const web_graphics = options.mode;
    const root_file_name = options.root_mod_filename;
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
        .with_tracing = true,
        .wgpu = web_graphics == .webgpu,
    });

    const cimgui_config = cimgui.getConfig(false);
    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_config.include_dir));

    // extract shdc dependency from sokol dependency
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});

    const dep_zgltf = b.dependency("zgltf", .{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path(root_file_name),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
            .{ .name = "zgltf", .module = dep_zgltf.module("zgltf") },
        },
    });
    return .{
        .dep_sokol = dep_sokol,
        .dep_cimgui = dep_cimgui,
        .dep_shdc = dep_shdc,
        .target = target,
        .optimize = optimize,
        .root_mod = root_mod,
    };
}

fn compileShaders(b: *std.Build, options: Options) !*std.Build.Step {
    const shdc_step = try sokol.shdc.createSourceFile(b, .{
        .shdc_dep = options.dep_shdc,
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

    return shdc_step;
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    print(format, args);
    std.process.exit(1);
}

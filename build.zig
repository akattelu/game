const std = @import("std");
const sokol = @import("sokol");
const cimgui = @import("cimgui");
const ig = @import("cimgui");

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
        .slang = .{ .metal_macos = true, .spirv_vk = true },
    });

    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sokol", .module = dep_sokol.module("sokol") },
                .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
            },
        }),
    });
    // add the shader compilation step as dependency to the build step
    // which requires the generated Zig source file
    exe.step.dependOn(shdc_step);

    b.installArtifact(exe);

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

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

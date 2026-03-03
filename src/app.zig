const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const simgui = sokol.imgui;
const sgimgui = sokol.sgimgui;

const ig = @import("cimgui");

pub const App = struct {
    event: *const fn (e: [*c]const sapp.Event) callconv(.c) void,
    ui: *const fn () callconv(.c) void,
    init: *const fn () callconv(.c) void,
    cleanup: *const fn () callconv(.c) void,
    frame: *const fn () callconv(.c) void,
};

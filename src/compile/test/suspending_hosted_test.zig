//! A `suspending` hosted declaration reaches the checked artifact's
//! `HostedProc` (design.md "Suspendable Effects", Explicit Inputs). Only the
//! marked declaration is suspending; its unmarked sibling is not. A platform
//! that doesn't declare `concurrency: Tasks` can't have a suspending one.

const std = @import("std");
const roc_target = @import("roc_target");

const compile_build = @import("../compile_build.zig");
const BuildEnv = compile_build.BuildEnv;

const TestError = std.Io.Dir.WriteFileError ||
    std.Io.Dir.RealPathFileAllocError ||
    compile_build.InitError ||
    compile_build.BuildRootError ||
    error{ TestUnexpectedResult, TestExpectedEqual };

const host_source =
    \\Host := [].{
    \\    suspending fetch! : Str => Str
    \\    log! : Str => {}
    \\}
    \\
;

fn mainSource(comptime concurrency_field: []const u8) []const u8 {
    return main_head ++ concurrency_field ++ main_tail;
}

const main_head =
    \\platform ""
    \\    requires {
    \\        main! : Str => Str
    \\    }
    \\    exposes [Host]
    \\    packages {}
    \\    provides { "roc_main": main_for_host! }
    \\    hosted {
    \\        "roc_host_fetch": Host.fetch!,
    \\        "roc_host_log": Host.log!,
    \\    }
    \\
;

const main_tail =
    \\
    \\import Host
    \\
    \\main_for_host! : Str => Str
    \\main_for_host! = |url| {
    \\    Host.log!(url)
    \\    main!(Host.fetch!(url))
    \\}
    \\
;

/// Builds the platform in `dir`, rooted at `main.roc`.
fn buildPlatform(build_env: *BuildEnv, dir: *std.testing.TmpDir, main_source: []const u8) TestError!void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try dir.dir.writeFile(io, .{ .sub_path = "Host.roc", .data = host_source });
    try dir.dir.writeFile(io, .{ .sub_path = "main.roc", .data = main_source });

    const cwd = try dir.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd);
    const main_path = try dir.dir.realPathFileAlloc(io, "main.roc", gpa);
    defer gpa.free(main_path);

    build_env.* = try BuildEnv.init(gpa, .single_threaded, 1, roc_target.RocTarget.detectNative(), cwd, io, .lss);
    errdefer build_env.deinit();
    try build_env.build(main_path);
}

/// Whether the build reported a problem titled `title`, and whether it
/// reported anything at all.
fn reportTitles(build_env: *BuildEnv, title: []const u8) TestError!struct { found: bool, any: bool } {
    const drained = try build_env.drainReports();
    defer build_env.freeDrainedReports(drained);
    var found = false;
    var any = false;
    for (drained) |module_reports| {
        for (module_reports.reports) |report| {
            any = true;
            if (std.mem.eql(u8, report.title, title)) found = true;
        }
    }
    return .{ .found = found, .any = any };
}

test "suspending marks only its own hosted procedure" {
    var build_env: BuildEnv = undefined;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try buildPlatform(&build_env, &tmp_dir, comptime mainSource("    concurrency: Tasks\n"));
    defer build_env.deinit();

    const coord = build_env.coordinator.?;
    try std.testing.expect(!coord.hasUserErrors());

    const artifact = artifact: {
        var packages = coord.packages.iterator();
        while (packages.next()) |package| {
            for (package.value_ptr.*.modules.items) |*module| {
                if (std.mem.eql(u8, module.name, "Host")) break :artifact module.checkedArtifact().?;
            }
        }
        return error.TestUnexpectedResult;
    };

    var saw_fetch = false;
    var saw_log = false;
    for (artifact.hosted_procs.procs.items()) |proc| {
        const key = proc.orderKey(&artifact.hosted_procs);
        if (std.mem.eql(u8, key, "Host.fetch")) {
            try std.testing.expect(proc.suspending);
            saw_fetch = true;
        } else if (std.mem.eql(u8, key, "Host.log")) {
            try std.testing.expect(!proc.suspending);
            saw_log = true;
        }
    }
    try std.testing.expect(saw_fetch and saw_log);
}

// The same platform builds clean with `concurrency: Tasks` (above), so the
// hosted section problem here comes from the mode alone.
test "a suspending hosted function needs concurrency: Tasks" {
    inline for (.{ "", "    concurrency: None\n" }) |field| {
        var build_env: BuildEnv = undefined;
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        try buildPlatform(&build_env, &tmp_dir, comptime mainSource(field));
        defer build_env.deinit();

        const result = try reportTitles(&build_env, "Invalid Hosted Section");
        try std.testing.expect(result.found);
    }
}

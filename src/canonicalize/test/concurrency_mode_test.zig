//! Tests for the `concurrency` mode a platform header may name.

const std = @import("std");
const base = @import("base");
const parse = @import("parse");
const Can = @import("../Can.zig");
const ModuleEnv = @import("../ModuleEnv.zig");
const BuiltinTestContext = @import("BuiltinTestContext.zig").BuiltinTestContext;
const CoreCtx = @import("ctx").CoreCtx;

const Outcome = struct {
    mode: base.ConcurrencyMode,
    unknown_mode: bool,
    not_implemented: bool,
};

/// Canonicalize a platform whose header carries `field` after `provides`,
/// and say which mode it recorded and which mode diagnostics it produced.
fn canonicalizePlatform(allocator: std.mem.Allocator, field: []const u8) (std.mem.Allocator.Error || error{TestUnexpectedResult})!Outcome {
    var builtin_ctx = try BuiltinTestContext.init(allocator);
    defer builtin_ctx.deinit();

    const source = try std.mem.concat(allocator, u8, &.{
        \\platform "test-platform"
        \\    requires {}
        \\    exposes []
        \\    packages {}
        \\    provides {}
        \\
        ,
        field,
        \\
        \\
        \\helper = 1
        \\
    });
    defer allocator.free(source);

    var env = try ModuleEnv.init(allocator, source);
    defer env.deinit();
    try env.initCIRFields("main");

    const ast = try parse.file(allocator, &env.common);
    defer ast.deinit();

    const roc_ctx = CoreCtx.testing(allocator, allocator);
    var can = try Can.initModule(roc_ctx, &env, ast, builtin_ctx.canInitContext());
    defer can.deinit();
    try can.canonicalizeFile();

    const diagnostics = try env.getDiagnostics();
    defer allocator.free(diagnostics);

    var outcome: Outcome = .{ .mode = env.concurrency_mode, .unknown_mode = false, .not_implemented = false };
    for (diagnostics) |diagnostic| {
        if (diagnostic == .unknown_concurrency_mode) outcome.unknown_mode = true;
        if (diagnostic == .not_implemented) outcome.not_implemented = true;
    }
    return outcome;
}

test "a platform without the field has mode None" {
    const outcome = try canonicalizePlatform(std.testing.allocator, "");
    try std.testing.expectEqual(base.ConcurrencyMode.none, outcome.mode);
    try std.testing.expect(!outcome.unknown_mode and !outcome.not_implemented);
}

test "Tasks and None are recorded" {
    const tasks = try canonicalizePlatform(std.testing.allocator, "    concurrency: Tasks");
    try std.testing.expectEqual(base.ConcurrencyMode.tasks, tasks.mode);
    try std.testing.expect(!tasks.unknown_mode and !tasks.not_implemented);

    const none = try canonicalizePlatform(std.testing.allocator, "    concurrency: None");
    try std.testing.expectEqual(base.ConcurrencyMode.none, none.mode);
    try std.testing.expect(!none.unknown_mode and !none.not_implemented);
}

test "an unknown mode is reported and recorded as None" {
    const outcome = try canonicalizePlatform(std.testing.allocator, "    concurrency: Async");
    try std.testing.expect(outcome.unknown_mode);
    try std.testing.expectEqual(base.ConcurrencyMode.none, outcome.mode);
}

test "ParallelTasks is reported as not implemented and recorded as None" {
    const outcome = try canonicalizePlatform(std.testing.allocator, "    concurrency: ParallelTasks");
    try std.testing.expect(outcome.not_implemented);
    try std.testing.expect(!outcome.unknown_mode);
    try std.testing.expectEqual(base.ConcurrencyMode.none, outcome.mode);
}

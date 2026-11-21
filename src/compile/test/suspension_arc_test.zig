//! ARC's rules for procedures that may suspend (design.md "The Continuation
//! Pass"): such a procedure returns an owned result even where the same
//! body without a suspension site would return a borrow of its argument.

const std = @import("std");
const layout = @import("layout");
const lir = @import("lir");

const harness = @import("lower_to_lir_harness.zig");

const Seen = struct {
    after_fetch: ?struct { suspends: lir.LIR.Suspends, ret_borrowed: bool } = null,
    after_log: ?struct { suspends: lir.LIR.Suspends, ret_borrowed: bool } = null,
};

var seen: Seen = .{};

fn collect(store: *const lir.LirStore, _: *const layout.Store) harness.LowerToLirHarnessError!void {
    seen = .{};
    for (0..store.getProcSpecs().len) |index| {
        const proc_id: lir.LIR.LirProcSpecId = @fromBackingInt(@intCast(index));
        const proc = store.getProcSpec(proc_id);
        const name = store.procDebugName(proc_id) orelse continue;
        if (std.mem.eql(u8, name, "keep_after_fetch!")) seen.after_fetch = .{ .suspends = proc.suspends, .ret_borrowed = proc.rc_ret_borrowed };
        if (std.mem.eql(u8, name, "keep_after_log!")) seen.after_log = .{ .suspends = proc.suspends, .ret_borrowed = proc.rc_ret_borrowed };
    }
}

test "a procedure that may suspend returns an owned result" {
    try harness.runAppPathLirInspection(
        "test/postcheck/suspension_arc/app.roc",
        .{ .inline_mode = .none },
        collect,
    );
    const after_log = seen.after_log orelse return error.TestUnexpectedResult;
    const after_fetch = seen.after_fetch orelse return error.TestUnexpectedResult;
    // Without a suspension site, returning the argument returns a borrow.
    try std.testing.expectEqual(lir.LIR.Suspends.never, after_log.suspends);
    try std.testing.expect(after_log.ret_borrowed);
    try std.testing.expectEqual(lir.LIR.Suspends.may, after_fetch.suspends);
    try std.testing.expect(!after_fetch.ret_borrowed);
}

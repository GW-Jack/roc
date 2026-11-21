//! LIR construction seeds `suspends = may` from a `suspending` hosted
//! declaration, and the marks pass carries it to every caller (design.md
//! "Suspendability"). Without a `suspending` declaration, every procedure
//! stays `never` and no call is a suspension site.

const std = @import("std");
const layout = @import("layout");
const lir = @import("lir");

const harness = @import("lower_to_lir_harness.zig");

const Marks = struct {
    fetch: ?lir.LIR.Suspends = null,
    log: ?lir.LIR.Suspends = null,
    main_for_host: ?lir.LIR.Suspends = null,
    fetch_both: ?lir.LIR.Suspends = null,
    note: ?lir.LIR.Suspends = null,
    main: ?lir.LIR.Suspends = null,
    fetch_both_sites: usize = 0,
    main_for_host_sites: usize = 0,
    may_procs: usize = 0,
    sites: usize = 0,
    sites_in_never_procs: usize = 0,
};

var marks: Marks = .{};

fn procMark(store: *const lir.LirStore, layouts: *const layout.Store, buf: []u8, index: usize) harness.LowerToLirHarnessError!void {
    const proc_id: lir.LIR.LirProcSpecId = @fromBackingInt(@intCast(index));
    const proc = store.getProcSpec(proc_id);
    if (proc.suspends == .may) marks.may_procs += 1;

    var writer = std.Io.Writer.fixed(buf);
    try lir.DebugPrint.writeProc(std.testing.allocator, store, layouts, proc_id, &writer);
    const sites = std.mem.count(u8, writer.buffered(), " suspension_site");
    marks.sites += sites;
    if (proc.suspends == .never) marks.sites_in_never_procs += sites;

    if (proc.hosted.get()) |hosted| {
        const symbol = store.getString(hosted.symbol);
        if (std.mem.eql(u8, symbol, "roc_host_fetch")) marks.fetch = proc.suspends;
        if (std.mem.eql(u8, symbol, "roc_host_log")) marks.log = proc.suspends;
        return;
    }
    const name = store.procDebugName(proc_id) orelse return;
    if (std.mem.eql(u8, name, "main_for_host!")) {
        marks.main_for_host = proc.suspends;
        marks.main_for_host_sites = sites;
    }
    if (std.mem.eql(u8, name, "fetch_both!")) {
        marks.fetch_both = proc.suspends;
        marks.fetch_both_sites = sites;
    }
    if (std.mem.eql(u8, name, "note!")) marks.note = proc.suspends;
    if (std.mem.eql(u8, name, "main!")) marks.main = proc.suspends;
}

fn collectMarks(store: *const lir.LirStore, layouts: *const layout.Store) harness.LowerToLirHarnessError!void {
    marks = .{};
    const buf = try std.testing.allocator.alloc(u8, 1 << 22);
    defer std.testing.allocator.free(buf);
    for (0..store.getProcSpecs().len) |index| try procMark(store, layouts, buf, index);
}

test "a suspending hosted call marks its caller and the caller's callers" {
    try harness.runAppPathLirInspection(
        "test/postcheck/suspension_marks/app.roc",
        .{ .inline_mode = .none },
        collectMarks,
    );
    try std.testing.expectEqual(@as(?lir.LIR.Suspends, .may), marks.fetch);
    try std.testing.expectEqual(@as(?lir.LIR.Suspends, .never), marks.log);
    try std.testing.expectEqual(@as(?lir.LIR.Suspends, .may), marks.fetch_both);
    try std.testing.expectEqual(@as(?lir.LIR.Suspends, .may), marks.main_for_host);
    try std.testing.expectEqual(@as(?lir.LIR.Suspends, .never), marks.note);
    try std.testing.expectEqual(@as(?lir.LIR.Suspends, .never), marks.main);
    // The two calls to `Host.fetch!`, and the one to `fetch_both!`; a call
    // site's mark always sits in a procedure that may suspend.
    try std.testing.expectEqual(@as(usize, 2), marks.fetch_both_sites);
    try std.testing.expectEqual(@as(usize, 1), marks.main_for_host_sites);
    try std.testing.expectEqual(@as(usize, 0), marks.sites_in_never_procs);
}

test "without a suspending declaration every procedure stays never" {
    try harness.runAppPathLirInspection(
        "test/postcheck/issue_11287_hosted_try_return/app.roc",
        .{ .inline_mode = .none },
        collectMarks,
    );
    try std.testing.expectEqual(@as(usize, 0), marks.may_procs);
    try std.testing.expectEqual(@as(usize, 0), marks.sites);
}

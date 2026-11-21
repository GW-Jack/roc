//! Milestone 1, end to end (design.md "What Implements It First"): a
//! program whose platform declares `concurrency: Tasks` and calls a
//! `suspending` hosted function compiles under `.lss` and runs on the
//! interpreter as a task. A host that pauses at every suspending call gives
//! the same result and the same hosted-call trace as a host that finishes
//! each at once, and neither leaves a live allocation. Cancelling at each
//! pause, before or after the host finishes the operation, also leaves
//! none.
//!
//! The program's root is the task entry the continuation pass builds: the
//! test calls it as a host calls a `provides` entry and drives the task it
//! returns.

const std = @import("std");
const lir = @import("lir");
const eval = @import("eval");
const builtins = @import("builtins");

const harness = @import("lower_to_lir_harness.zig");
const task_test_host = @import("task_test_host.zig");

const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;
const TestHost = task_test_host.TestHost;

const app_path = "test/postcheck/suspension_marks/app.roc";
const url = "https://example.com/a/path/long/enough/for/the/heap";
const expected_result = url ++ "/body" ++ url ++ "/body!";
const expected_trace = [_][]const u8{ "log(" ++ url ++ ")", "fetch(" ++ url ++ ")", "fetch(" ++ url ++ ")" };
/// `fetch_both!` calls `fetch!` twice, so the task pauses twice.
const pause_count = 2;

const E2eError = std.mem.Allocator.Error || eval.LirInterpreter.Error || eval.RuntimeHostEnv.LeakError || error{ TestUnexpectedResult, TestExpectedEqual };

/// One interpreter over the lowered program, with the test host's handler.
const Run = struct {
    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    static_data: ?eval.InterpreterStaticData,
    static_strings: eval.LirInterpreter.StaticStrings.Table,
    interpreter: eval.LirInterpreter,

    fn init(self: *Run, lowered: *const lir.CheckedPipeline.LoweredProgram, mode: task_test_host.Mode) E2eError!void {
        const program = &lowered.lir_result;
        self.runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
        const ops = self.runtime.get_ops();
        self.host = TestHost.init(std.testing.allocator, ops, mode);
        self.static_data = try harness.interpreterStaticData(lowered);
        self.static_strings = try eval.LirInterpreter.buildStaticStrings(std.testing.allocator, &program.store);
        self.interpreter = try eval.LirInterpreter.init(std.testing.allocator, &program.store, &program.layouts, self.static_strings.view(), ops);
        self.interpreter.hosted_call_handler = self.host.handler();
        if (self.static_data) |*data| {
            data.install(&self.interpreter);
            data.ownByInterpreter(&self.interpreter);
        }
    }

    fn deinit(self: *Run) void {
        self.interpreter.deinit();
        self.static_strings.deinit();
        if (self.static_data) |*data| data.deinit();
        self.host.deinit();
        self.runtime.deinit();
    }

    /// Make the root's task by calling the program's root, the task entry
    /// `E(url, result_out)` the continuation pass put in the root's place
    /// (design.md "Host Contract"): it creates the task, whose result goes
    /// to `result`, and returns it.
    fn startRoot(self: *Run, lowered: *const lir.CheckedPipeline.LoweredProgram, result: *RocStr) E2eError!*RocTask {
        const program = &lowered.lir_result;
        const entry_id = program.root_procs.items[0];
        const entry = program.store.getProcSpec(entry_id);
        // The root returns the task, not the program's `Str`.
        try std.testing.expectEqual(@import("layout").Idx.opaque_ptr, entry.ret_layout);
        const ops = self.runtime.get_ops();
        const url_str = RocStr.fromSlice(url, ops);
        var entry_args = EntryArgs{ .url = url_str, .result_out = result };
        var task: *RocTask = undefined;
        _ = try self.interpreter.eval(.{
            .proc_id = entry_id,
            .arg_layouts = &.{ .str, .opaque_ptr },
            .ret_layout = entry.ret_layout,
            .arg_ptr = @ptrCast(&entry_args),
            .ret_ptr = @ptrCast(&task),
        });
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) url_str.decref(ops);
        return task;
    }
};

/// The task entry's arguments, laid out as the entrypoint ABI lays them out.
const EntryArgs = extern struct { url: RocStr, result_out: *RocStr };

fn expectTrace(host: *const TestHost) E2eError!void {
    try std.testing.expectEqual(expected_trace.len, host.trace.items.len);
    for (expected_trace, host.trace.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn runToEnd(lowered: *const lir.CheckedPipeline.LoweredProgram, mode: task_test_host.Mode) E2eError!void {
    var run: Run = undefined;
    try run.init(lowered, mode);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(lowered, &result);
    try std.testing.expectEqual(builtins.task.Status.done, try run.host.drive(task));
    task.free();
    try std.testing.expectEqualStrings(expected_result, result.asSlice());
    result.decref(run.runtime.get_ops());
    try expectTrace(&run.host);
    try std.testing.expectEqual(@as(u32, if (mode == .pause) pause_count else 0), run.host.pauses);
    try run.runtime.checkForLeaks();
}

fn cancelAt(lowered: *const lir.CheckedPipeline.LoweredProgram, pause: u32, woken: bool) E2eError!void {
    var run: Run = undefined;
    try run.init(lowered, .pause);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(lowered, &result);
    try std.testing.expectEqual(builtins.task.Status.cancelled, try run.host.driveAndCancel(task, pause, woken));
    task.free();
    try std.testing.expectEqual(@as(u32, if (woken) 0 else 1), run.host.aborts);
    try run.runtime.checkForLeaks();
}

fn runAll(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    checkAll(lowered) catch |err| {
        std.log.err("tasks end-to-end run failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn checkAll(lowered: *const lir.CheckedPipeline.LoweredProgram) E2eError!void {
    try runToEnd(lowered, .ready);
    try runToEnd(lowered, .pause);
    for (1..pause_count + 1) |pause| {
        for ([_]bool{ false, true }) |woken| try cancelAt(lowered, @intCast(pause), woken);
    }
}

test "a Tasks program pauses at every suspending call and gives the same result with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAll);
}

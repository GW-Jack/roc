//! The pausing programs of `task_ops_lir_test.zig`, compiled by the dev
//! backend and run in this process against a C-ABI pausing host
//! (design.md "Backends"): the same outcomes as the interpreter's, from
//! records compiled code packs.

const std = @import("std");
const builtins = @import("builtins");
const backend = @import("backend");
const lir = @import("lir");
const roc_target = @import("roc_target");
const lir_test = @import("task_ops_lir_test.zig");

const LIR = lir.LIR;
const RocTask = builtins.task.RocTask;
const Fixture = lir_test.Fixture;
const ExecutableMemory = backend.ExecutableMemory;

const DevTaskTestError = lir_test.TaskOpsTestError || error{
    EmptyCode,
    MmapFailed,
    VirtualAllocFailed,
    MprotectFailed,
    VirtualProtectFailed,
    FlushInstructionCacheFailed,
    UnsupportedPlatform,
    UnwindRegistrationFailed,
};

/// What the C-ABI test host saw at its one suspending hosted call. Compiled
/// code calls it through a plain function pointer, so it lives in a global.
const PausingHost = struct {
    calls: u32 = 0,
    task: ?*RocTask = null,
    slot: ?[*]u8 = null,
    x: u64 = 0,

    var seen: PausingHost = .{};

    /// `roc_test_pause` after the continuation pass:
    /// `u32 f(RocTask *task, T *out, u64 x)`. Pending: the host writes the
    /// slot and wakes the task later.
    fn pause(task: *RocTask, out: [*]u8, x: u64) callconv(.c) u32 {
        seen.calls += 1;
        seen.task = task;
        seen.slot = out;
        seen.x = x;
        return 1;
    }

    fn resolve(_: *const anyopaque, name: []const u8) ?usize {
        return if (std.mem.eql(u8, name, "roc_test_pause")) @intFromPtr(&pause) else null;
    }
};

/// `f`'s program compiled by the dev backend, kept alive while its records
/// are.
const DevRun = struct {
    executable: ExecutableMemory,
    entered: builtins.in_process_host.Saved,

    /// Compile every procedure, with the task entry as the entrypoint, and
    /// enter `f`'s runtime host: compiled records call builtins that read
    /// the entered ops for the task's whole life.
    fn init(self: *DevRun, f: *Fixture, entry: LIR.LirProcSpecId) DevTaskTestError!void {
        PausingHost.seen = .{};
        // Code generation takes LIR after ARC, which the pipeline runs after
        // the continuation pass, with the task entry as a root.
        _ = try lir.Arc.insert(&f.store, &f.layouts, .{ .roots = &.{entry} });
        var static_strings = try backend.StaticStringData.build(f.allocator, &f.store, backend.dev.LirCodeGenMod.host_lir_codegen_target);
        defer static_strings.deinit();
        var codegen = try backend.HostLirCodeGen.initWithCapturePrefix(f.allocator, &f.store, &f.layouts, static_strings.view(), 0, roc_target.host_cpu.level());
        defer codegen.deinit();
        const resolver_context: u8 = 0;
        codegen.setHostedSymbolResolver(.{ .context = &resolver_context, .resolve = PausingHost.resolve });
        try codegen.compileAllProcSpecs(f.store.getProcSpecs());
        const entrypoint = try codegen.generateEntrypointWrapper("roc_task_entry", entry, &.{ .u64, .opaque_ptr }, .opaque_ptr);
        try codegen.finishImage();
        self.executable = try ExecutableMemory.initWithEntryOffsetAndUnwindInfo(
            codegen.getGeneratedCode(),
            entrypoint.offset,
            codegen.getUnwindFunctions(),
        );
        self.entered = builtins.in_process_host.enter(f.runtime_env.get_ops(), null);
    }

    fn deinit(self: *DevRun) void {
        builtins.in_process_host.leave(self.entered);
        self.executable.deinit();
    }

    /// Call the task entry as the host calls a provides entry, with 20 and
    /// the root result's address, and return the task it creates.
    fn start(self: *DevRun, root: [*]u8) *RocTask {
        const Args = extern struct { x: u64, result_out: usize };
        var args = Args{ .x = 20, .result_out = @intFromPtr(root) };
        var created: usize = 0;
        self.executable.callRocABI(@ptrCast(&created), @ptrCast(&args));
        return @ptrFromInt(created);
    }
};

test "a task paused at a hosted call resumes from its record and returns the root result on the dev backend" {
    if (comptime !backend.host_lir_codegen_available) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try lir_test.pausingProgram(&f, .u64, true);
    var run: DevRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    var root: u64 = 0;
    const task = run.start(@ptrCast(&root));
    const host = &PausingHost.seen;

    // The first run reaches the hosted call, which is pending: the task
    // parks with g's record saved.
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());
    try std.testing.expectEqual(@as(u32, 1), host.calls);
    try std.testing.expectEqual(task, host.task.?);
    try std.testing.expectEqual(@as(u64, 20), host.x);
    try std.testing.expectEqual(@as(usize, 1), task.len);

    // The host finishes: it writes the result and wakes the task, which
    // resumes in g's continuation with x restored from the record.
    @as(*align(1) u64, @ptrCast(host.slot.?)).* = 22;
    task.wake();
    try std.testing.expectEqual(builtins.task.Status.done, task.resumeTask());
    try std.testing.expectEqual(@as(u64, 42), root);
    try std.testing.expectEqual(@as(u32, 1), host.calls);
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "a task paused inside a called procedure resumes in its caller's continuation on the dev backend" {
    if (comptime !backend.host_lir_codegen_available) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try lir_test.pausingNestedProgram(&f);
    var run: DevRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    var root: u64 = 0;
    const task = run.start(@ptrCast(&root));
    const host = &PausingHost.seen;

    // k saves its record at the hosted call; g reads the pending flag with
    // task_ready after k returns and saves its own record.
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());
    try std.testing.expectEqual(@as(u64, 20), host.x);
    try std.testing.expectEqual(@as(usize, 2), task.len);
    @as(*align(1) u64, @ptrCast(host.slot.?)).* = 22;
    task.wake();
    try std.testing.expectEqual(builtins.task.Status.done, task.resumeTask());
    try std.testing.expectEqual(@as(u64, 42), root);
    try std.testing.expectEqual(@as(u32, 1), host.calls);
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "cancelling a woken task releases the hosted result in its slot and its records on the dev backend" {
    if (comptime !backend.host_lir_codegen_available) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try lir_test.pausingProgram(&f, .str, false);
    var run: DevRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    var root: u64 = 0;
    const task = run.start(@ptrCast(&root));
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());

    // The host writes a heap string and wakes the task, which is then
    // cancelled instead of resumed: the record's slot release frees the
    // string, and no abort runs.
    const text = builtins.str.RocStr.fromSlice("a string too long to be small", f.runtime_env.get_ops());
    try std.testing.expect(!text.isSmallStr());
    @as(*align(1) builtins.str.RocStr, @ptrCast(PausingHost.seen.slot.?)).* = text;
    task.wake();
    task.cancel(&lir_test.abortUnexpected);
    try std.testing.expectEqual(builtins.task.Status.cancelled, task.status);
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "cancelling a task the host has not finished aborts the host call and releases its records on the dev backend" {
    if (comptime !backend.host_lir_codegen_available) return error.SkipZigTest;
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try lir_test.pausingProgram(&f, .str, false);
    var run: DevRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    var root: u64 = 0;
    const task = run.start(@ptrCast(&root));
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());

    lir_test.aborted = null;
    task.cancel(&lir_test.abortRecord);
    try std.testing.expectEqual(task, lir_test.aborted.?);
    task.free();
    try f.runtime_env.checkForLeaks();
}

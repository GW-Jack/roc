//! LIR-level tests for the task operations (design.md "Records And The
//! Task"), run through the interpreter on hand-built LIR against a
//! `RocTask`.

const std = @import("std");
const base = @import("base");
const builtins = @import("builtins");
const eval = @import("eval");
const layout = @import("layout");
const lir = @import("lir");
const RuntimeHostEnv = eval.RuntimeHostEnv;

const Allocator = std.mem.Allocator;
const LIR = lir.LIR;
const LirStore = lir.LirStore;
const LocalId = LIR.LocalId;
const CFStmtId = LIR.CFStmtId;
const LowLevel = lir.LowLevel;
const RocTask = builtins.task.RocTask;

const TaskOpsTestError = Allocator.Error || eval.Interpreter.Error || RuntimeHostEnv.LeakError || error{
    TestExpectedEqual,
    TestUnexpectedResult,
};

const Fixture = struct {
    allocator: Allocator,
    store: LirStore,
    layouts: layout.Store,
    runtime_env: RuntimeHostEnv,
    locals: std.ArrayList(LocalId) = .empty,

    fn init(allocator: Allocator) TaskOpsTestError!Fixture {
        var store = LirStore.init(allocator);
        errdefer store.deinit();
        return .{
            .allocator = allocator,
            .store = store,
            .layouts = try layout.Store.init(allocator, base.target.TargetUsize.native),
            .runtime_env = RuntimeHostEnv.init(allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.locals.deinit(self.allocator);
        self.runtime_env.deinit();
        self.layouts.deinit();
        self.store.deinit();
    }

    fn local(self: *Fixture, layout_idx: layout.Idx) TaskOpsTestError!LocalId {
        const id = try self.store.addLocal(.{ .layout_idx = layout_idx });
        try self.locals.append(self.allocator, id);
        return id;
    }

    fn op(self: *Fixture, target: LocalId, low_level: LowLevel, args: []const LocalId, next: CFStmtId) TaskOpsTestError!CFStmtId {
        return try self.store.addCFStmt(.{ .assign_low_level = .{
            .target = target,
            .op = low_level,
            .rc_effect = try self.store.addRcEffect(low_level.rcEffect()),
            .args = try self.store.addLocalSpan(args),
            .next = next,
        } }, .test_fixture);
    }

    fn ret(self: *Fixture, value: LocalId) TaskOpsTestError!CFStmtId {
        return try self.store.addCFStmt(.{ .ret = .{ .value = value } }, .test_fixture);
    }

    /// Run a procedure of one task argument, returning its `ret_layout`
    /// result's first `T`.
    fn run(self: *Fixture, comptime T: type, task_arg: LocalId, body: CFStmtId, ret_layout: layout.Idx, task: *RocTask) TaskOpsTestError!T {
        const proc = try self.store.addProcSpec(.{
            .name = self.store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.programLocal("task-ops-test", self.store.next_synthetic_symbol),
            .args = try self.store.addLocalSpan(&.{task_arg}),
            .frame_locals = try self.store.addLocalSpan(self.locals.items),
            .body = .some(body),
            .ret_layout = ret_layout,
        }, .none);
        var static_strings = try eval.Interpreter.buildStaticStrings(self.allocator, &self.store);
        defer static_strings.deinit();
        var interp = try eval.Interpreter.init(self.allocator, &self.store, &self.layouts, static_strings.view(), self.runtime_env.get_ops());
        defer interp.deinit();
        var address: usize = @intFromPtr(task);
        const result = try interp.eval(.{
            .proc_id = proc,
            .arg_layouts = &.{.opaque_ptr},
            .arg_ptr = @ptrCast(&address),
        });
        return result.value.read(T);
    }
};

/// A task with the fields the operations read and nothing the runtime uses:
/// these tests run no records.
fn bareTask(hosted_slot: [*]u8, result_buffer: [*]u8) RocTask {
    return .{
        .pending = 0,
        .hosted_slot = hosted_slot,
        .result_buffer = result_buffer,
        .woken = false,
        .status = .pending,
        .root_result = undefined,
        .entries = undefined,
        .len = 0,
        .capacity = 0,
        .hosted_slot_size = 0,
        .hosted_slot_alignment = 1,
        .result_buffer_size = 0,
        .result_buffer_alignment = 1,
        .ops = undefined,
    };
}

test "task_ready reads the pending flag and task_set_pending sets it" {
    var slot: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var task = bareTask(&slot, &buffer);
    for ([_]bool{ false, true }) |set_first| {
        var f = try Fixture.init(std.testing.allocator);
        defer f.deinit();
        // [task_set_pending(task);] ret task_ready(task)
        const task_arg = try f.local(.opaque_ptr);
        const ready = try f.local(.bool);
        const unit = try f.local(.zst);
        const ret = try f.ret(ready);
        const read = try f.op(ready, .task_ready, &.{task_arg}, ret);
        const body = if (set_first) try f.op(unit, .task_set_pending, &.{task_arg}, read) else read;

        try std.testing.expectEqual(@as(u8, if (set_first) 0 else 1), try f.run(u8, task_arg, body, .bool, &task));
        try std.testing.expectEqual(set_first, !task.ready());
        try f.runtime_env.checkForLeaks();
    }
}

test "task_hosted_slot and task_result_buffer address the task's buffers" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var slot: u64 = 77;
    var buffer: u64 = 0;
    var task = bareTask(@ptrCast(&slot), @ptrCast(&buffer));
    const ptr_u64 = try f.layouts.insertPtr(.u64);

    // buffer.* = slot.* + 1; ret slot.*
    const task_arg = try f.local(.opaque_ptr);
    const slot_ptr = try f.local(ptr_u64);
    const buffer_ptr = try f.local(ptr_u64);
    const value = try f.local(.u64);
    const one = try f.local(.u64);
    const next = try f.local(.u64);
    const unit = try f.local(.zst);
    const ret = try f.ret(value);
    const write = try f.op(unit, .ptr_store, &.{ buffer_ptr, next }, ret);
    const add = try f.op(next, .num_int_add_wrap, &.{ value, one }, write);
    const lit = try f.store.addCFStmt(.{ .assign_literal = .{
        .target = one,
        .value = .{ .i64_literal = .{ .value = 1, .layout_idx = .u64 } },
        .next = add,
    } }, .test_fixture);
    const load = try f.op(value, .ptr_load, &.{slot_ptr}, lit);
    const get_buffer = try f.op(buffer_ptr, .task_result_buffer, &.{task_arg}, load);
    const get_slot = try f.op(slot_ptr, .task_hosted_slot, &.{task_arg}, get_buffer);

    try std.testing.expectEqual(@as(u64, 77), try f.run(u64, task_arg, get_slot, .u64, &task));
    try std.testing.expectEqual(@as(u64, 78), buffer);
    try f.runtime_env.checkForLeaks();
}

/// What the test host saw at its one suspending hosted call.
const PausingHost = struct {
    calls: u32 = 0,
    task: ?*RocTask = null,
    slot: ?[*]u8 = null,
    x: u64 = 0,

    fn dispatch(context: *anyopaque, call: eval.Interpreter.HostedCall) eval.Interpreter.Error!void {
        const self: *PausingHost = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.task = @ptrFromInt(std.mem.readInt(usize, call.args[call.arg_offsets[0]..][0..@sizeOf(usize)], .little));
        self.slot = @ptrFromInt(std.mem.readInt(usize, call.args[call.arg_offsets[1]..][0..@sizeOf(usize)], .little));
        self.x = std.mem.readInt(u64, call.args[call.arg_offsets[2]..][0..8], .little);
        // Pending: the host writes the slot and wakes the task later.
        std.mem.writeInt(u32, call.ret[0..4], 1, .little);
    }
};

/// A program whose task pauses at a suspending hosted call `h(x)` with a
/// result of `hosted_ret`, after the continuation pass: the provides root
/// `g(x) = t = h(x); ret (if add then t + x else x)`. Returns the task entry
/// that takes `g`'s place among the roots.
fn pausingProgram(f: *Fixture, hosted_ret: layout.Idx, add: bool) TaskOpsTestError!LIR.LirProcSpecId {
    const allocator = f.allocator;
    const h_arg = try f.store.addLocal(.{ .layout_idx = .u64 });
    const h = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{h_arg}),
        .ret_layout = hosted_ret,
        .hosted = .some(.{ .symbol = try f.store.insertString("roc_test_pause"), .dispatch_index = 0 }),
        .suspends = .may,
    }, .none);
    const x = try f.store.addLocal(.{ .layout_idx = .u64 });
    const t = try f.store.addLocal(.{ .layout_idx = hosted_ret });
    const r = try f.store.addLocal(.{ .layout_idx = .u64 });
    const after = if (add) try f.op(r, .num_int_add_wrap, &.{ t, x }, try f.ret(r)) else try f.ret(x);
    const site = try f.store.addCFStmt(.{ .assign_call = .{
        .target = t,
        .proc = h,
        .args = try f.store.addLocalSpan(&.{x}),
        .next = after,
    } }, .test_fixture);
    const g = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{x}),
        .frame_locals = try f.store.addLocalSpan(&.{ x, t, r }),
        .body = .some(site),
        .ret_layout = .u64,
    }, .none);
    try lir.SuspensionMarks.run(allocator, &f.store);
    var roots = [_]LIR.LirProcSpecId{g};
    try lir.ContinuationPass.run(allocator, &f.store, &f.layouts, .{ .procs = &roots, .provided = &.{true} });
    return roots[0];
}

/// An interpreter for `f`'s program whose hosted calls go to `host`, kept
/// alive while its records are.
const PausingRun = struct {
    static_strings: eval.Interpreter.StaticStrings.Table,
    interp: eval.Interpreter,

    fn init(self: *PausingRun, f: *Fixture, host: *PausingHost) TaskOpsTestError!void {
        self.static_strings = try eval.Interpreter.buildStaticStrings(f.allocator, &f.store);
        errdefer self.static_strings.deinit();
        self.interp = try eval.Interpreter.init(f.allocator, &f.store, &f.layouts, self.static_strings.view(), f.runtime_env.get_ops());
        self.interp.hosted_call_handler = .{ .context = host, .dispatch = PausingHost.dispatch };
    }

    fn deinit(self: *PausingRun) void {
        self.interp.deinit();
        self.static_strings.deinit();
    }

    /// Call the task entry as the host calls a provides entry, with 20 and
    /// the root result's address, and return the task it creates.
    fn start(self: *PausingRun, entry: LIR.LirProcSpecId, root: [*]u8) TaskOpsTestError!*RocTask {
        const Args = extern struct { x: u64, result_out: usize };
        var args = Args{ .x = 20, .result_out = @intFromPtr(root) };
        const created = try self.interp.eval(.{
            .proc_id = entry,
            .arg_layouts = &.{ .u64, .opaque_ptr },
            .arg_ptr = @ptrCast(&args),
        });
        return @ptrFromInt(created.value.read(usize));
    }
};

test "a task paused at a hosted call resumes from its record and returns the root result" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingProgram(&f, .u64, true);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));

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

test "cancelling a woken task releases the hosted result in its slot and its records" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingProgram(&f, .str, false);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());

    // The host writes a heap string and wakes the task, which is then
    // cancelled instead of resumed: the record's slot release frees the
    // string, and no abort runs.
    const text = builtins.str.RocStr.fromSlice("a string too long to be small", f.runtime_env.get_ops());
    try std.testing.expect(!text.isSmallStr());
    @as(*align(1) builtins.str.RocStr, @ptrCast(host.slot.?)).* = text;
    task.wake();
    task.cancel(&abortUnexpected);
    try std.testing.expectEqual(builtins.task.Status.cancelled, task.status);
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "cancelling a task the host has not finished aborts the host call and releases its records" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingProgram(&f, .str, false);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());

    aborted = null;
    task.cancel(&abortRecord);
    try std.testing.expectEqual(task, aborted.?);
    task.free();
    try f.runtime_env.checkForLeaks();
}

var aborted: ?*RocTask = null;

fn abortRecord(task: *RocTask) callconv(.c) void {
    aborted = task;
}

fn abortUnexpected(_: *RocTask) callconv(.c) void {
    std.debug.panic("a woken task's cancel aborted the host call", .{});
}

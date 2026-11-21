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

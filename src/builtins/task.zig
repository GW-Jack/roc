//! The task a `concurrency: Tasks` program runs in (design.md "Records And
//! The Task"). LIR reaches it only through the `task_*` low-level
//! operations, which read and write its first three fields. The rest is the
//! runtime's: the record list, the root's result storage and the buffers'
//! sizes. Every backend shares it, since a record is called through the
//! erased-callable ABI.

const std = @import("std");

const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;

/// Releases the hosted result in `slot`, as the `slot_drop` RC helper
/// `suspend_save` names does. It also gets the hosted site's record, which
/// is where an interpreter's release finds its interpreter and the layout.
pub const SlotDropFn = *const fn (slot: [*]u8, record: [*]u8, ops: *RocOps) callconv(.c) void;

/// What `resume` reports, as `roc_task_resume` returns it.
pub const Status = enum(u8) {
    pending,
    done,
    cancelled,
};

/// One saved record: a boxed erased callable's data pointer, holding one
/// reference, and the release of the hosted result when it is a hosted
/// site's record.
pub const Entry = extern struct {
    record: [*]u8,
    slot_drop: ?SlotDropFn,
};

/// The host's `roc_task_abort`: abandon the operation a cancelled task is
/// parked on (design.md "Host Contract").
pub const AbortFn = *const fn (*RocTask) callconv(.c) void;

/// The sizes and alignments of a task's two buffers, which the continuation
/// pass records as program constants.
pub const BufferLayout = struct {
    hosted_slot_size: usize,
    hosted_slot_alignment: usize,
    result_buffer_size: usize,
    result_buffer_alignment: usize,
};

/// The C-ABI task calls a backend's runtime exports to the host (design.md
/// "Host Contract"). `roc_task_resume` returns a `RocTaskStatus`, a C enum:
/// `PENDING`, `DONE`, `CANCELLED` in `Status` order.
pub const host_calls = struct {
    pub fn resumeTask(task: *RocTask) callconv(.c) u32 {
        return @backingInt(task.resumeTask());
    }

    pub fn wake(task: *RocTask) callconv(.c) void {
        task.wake();
    }

    pub fn free(task: *RocTask) callconv(.c) void {
        task.free();
    }
};

/// Where compiled code finds the three fields the `task_*` low-level
/// operations reach, for a target whose pointers are `pointer_size` bytes
/// (design.md "Backends"): `pending` first, then the two buffer pointers,
/// each at the next pointer-aligned offset. The comptime check below holds
/// `RocTask` to it.
pub const FieldOffsets = struct {
    pending: u32,
    hosted_slot: u32,
    result_buffer: u32,

    /// The offsets on a target with `pointer_size`-byte pointers.
    pub fn forPointerSize(pointer_size: u32) FieldOffsets {
        return .{ .pending = 0, .hosted_slot = pointer_size, .result_buffer = 2 * pointer_size };
    }
};

comptime {
    const native = FieldOffsets.forPointerSize(@sizeOf(usize));
    if (@offsetOf(RocTask, "pending") != native.pending or
        @offsetOf(RocTask, "hosted_slot") != native.hosted_slot or
        @offsetOf(RocTask, "result_buffer") != native.result_buffer or
        @sizeOf(@FieldType(RocTask, "pending")) != 1)
        @compileError("RocTask's first three fields moved; compiled code reads them at FieldOffsets");
}

/// One task. The runtime owns it; LIR holds a pointer to it with no
/// reference count.
pub const RocTask = extern struct {
    /// Nonzero while the task is paused on an operation that has not
    /// finished. Resuming clears it.
    pending: u8,
    /// Where a `suspending` hosted procedure writes its result.
    hosted_slot: [*]u8,
    /// Where a resumed record writes the result of a procedure that may
    /// suspend, and where its caller's resume entry reads it.
    result_buffer: [*]u8,

    /// Whether the host wrote the hosted slot since the last resume.
    woken: bool,
    /// `pending` while the task can be resumed or cancelled.
    status: Status,
    /// Where the outermost record writes the root's result.
    root_result: [*]u8,
    /// The records, innermost last.
    entries: [*]Entry,
    len: usize,
    capacity: usize,
    hosted_slot_size: usize,
    hosted_slot_alignment: usize,
    result_buffer_size: usize,
    result_buffer_alignment: usize,
    ops: *RocOps,

    /// A task whose list holds `start`, the root's start record, and whose
    /// outermost record writes to `root_result`. The host's first resume
    /// runs it.
    pub fn create(ops: *RocOps, start: [*]u8, root_result: [*]u8, buffers: BufferLayout) *RocTask {
        const task: *RocTask = @ptrCast(@alignCast(ops.alloc(@alignOf(RocTask), @sizeOf(RocTask))));
        task.* = .{
            .pending = 0,
            .hosted_slot = allocBuffer(ops, buffers.hosted_slot_size, buffers.hosted_slot_alignment),
            .result_buffer = allocBuffer(ops, buffers.result_buffer_size, buffers.result_buffer_alignment),
            .woken = false,
            .status = .pending,
            .root_result = root_result,
            .entries = undefined,
            .len = 0,
            .capacity = 0,
            .hosted_slot_size = buffers.hosted_slot_size,
            .hosted_slot_alignment = buffers.hosted_slot_alignment,
            .result_buffer_size = buffers.result_buffer_size,
            .result_buffer_alignment = buffers.result_buffer_alignment,
            .ops = ops,
        };
        task.pushRecord(start, null);
        return task;
    }

    /// `task_ready`: whether the pending flag is clear.
    pub fn ready(self: *const RocTask) bool {
        return self.pending == 0;
    }

    /// `task_set_pending`.
    pub fn setPending(self: *RocTask) void {
        self.pending = 1;
    }

    /// What `suspend_save` does with the record it packs: the list takes the
    /// record's one reference.
    pub fn pushRecord(self: *RocTask, record: [*]u8, slot_drop: ?SlotDropFn) void {
        if (self.len == self.capacity) self.grow();
        self.entries[self.len] = .{ .record = record, .slot_drop = slot_drop };
        self.len += 1;
    }

    /// `roc_task_resume`: run records, innermost first, until the list is
    /// empty or the task pauses again.
    pub fn resumeTask(self: *RocTask) Status {
        if (self.status != .pending) utils.builtinInvariant(self.ops, "a finished or cancelled task was resumed");
        self.pending = 0;
        self.woken = false;
        while (self.len > 0) {
            self.len -= 1;
            const entry = self.entries[self.len];
            const base = self.len;
            self.call(entry.record, if (base == 0) self.root_result else self.result_buffer);
            std.mem.reverse(Entry, self.entries[base..self.len]);
            erased_callable.decref(entry.record, self.ops);
            if (self.pending != 0) return .pending;
        }
        self.status = .done;
        return .done;
    }

    /// `roc_task_wake`: the host wrote the hosted slot.
    pub fn wake(self: *RocTask) void {
        if (self.status != .pending or self.pending == 0) utils.builtinInvariant(self.ops, "a task was woken while not parked");
        self.woken = true;
    }

    /// `roc_task_cancel`: abandon the parked task's operation with `abort`
    /// unless the host already finished it, then release the hosted result
    /// the host wrote and every record.
    pub fn cancel(self: *RocTask, abort: AbortFn) void {
        if (self.status != .pending or self.pending == 0) utils.builtinInvariant(self.ops, "a task was cancelled while not parked");
        if (self.woken) {
            const innermost = self.entries[self.len - 1];
            if (innermost.slot_drop) |slot_drop| slot_drop(self.hosted_slot, innermost.record, self.ops);
        } else {
            abort(self);
        }
        while (self.len > 0) {
            self.len -= 1;
            erased_callable.decref(self.entries[self.len].record, self.ops);
        }
        self.status = .cancelled;
    }

    /// `roc_task_free`, after the task is done or cancelled.
    pub fn free(self: *RocTask) void {
        if (self.status == .pending) utils.builtinInvariant(self.ops, "a task was freed before it finished or was cancelled");
        const ops = self.ops;
        if (self.capacity > 0) ops.dealloc(@ptrCast(self.entries), @alignOf(Entry));
        freeBuffer(ops, self.hosted_slot, self.hosted_slot_size, self.hosted_slot_alignment);
        freeBuffer(ops, self.result_buffer, self.result_buffer_size, self.result_buffer_alignment);
        ops.dealloc(@ptrCast(self), @alignOf(RocTask));
    }

    fn call(self: *RocTask, record: [*]u8, ret: [*]u8) void {
        var task: *RocTask = self;
        var out_desc: ?*const anyopaque = null;
        erased_callable.payloadPtr(record).callable_fn_ptr(
            self.ops,
            ret,
            @ptrCast(&task),
            erased_callable.capturePtr(record),
            null,
            &out_desc,
        );
    }

    fn grow(self: *RocTask) void {
        const capacity = if (self.capacity == 0) 4 else self.capacity * 2;
        const bytes = capacity * @sizeOf(Entry);
        const raw = if (self.capacity == 0)
            self.ops.alloc(@alignOf(Entry), bytes)
        else
            self.ops.realloc(@ptrCast(self.entries), bytes, @alignOf(Entry));
        self.entries = @ptrCast(@alignCast(raw));
        self.capacity = capacity;
    }
};

/// A buffer no result is ever written to has no allocation.
var empty_buffer: [1]u8 align(16) = .{0};

fn allocBuffer(ops: *RocOps, size: usize, alignment: usize) [*]u8 {
    if (size == 0) return &empty_buffer;
    return @ptrCast(ops.alloc(alignment, size));
}

fn freeBuffer(ops: *RocOps, buffer: [*]u8, size: usize, alignment: usize) void {
    if (size == 0) return;
    ops.dealloc(@ptrCast(buffer), alignment);
}

// Tests drive the runtime with records built in Zig: each record's capture
// is a `TestStep` saying what its call does, and every call is logged.

const TestStep = extern struct {
    id: u8,
    /// Records this call saves before pausing, innermost first, or none.
    saves: [2]?[*]u8,
    /// Pause after saving, as a pending edge does.
    pauses: bool,
    /// What it writes through the result pointer.
    result: u8,
};

const TestLog = struct {
    var calls: [16]u8 = undefined;
    var call_count: usize = 0;
    var results_written_to: [16]?[*]u8 = undefined;
    var drops: usize = 0;
    var slot_drops: usize = 0;
    var aborts: usize = 0;

    fn reset() void {
        call_count = 0;
        drops = 0;
        slot_drops = 0;
        aborts = 0;
    }
};

fn testStepCall(_: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const TestStep = @ptrCast(@alignCast(capture.?));
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    TestLog.calls[TestLog.call_count] = step.id;
    TestLog.results_written_to[TestLog.call_count] = ret;
    TestLog.call_count += 1;
    for (step.saves) |save| if (save) |record| task.pushRecord(record, &testSlotDrop);
    if (step.pauses) task.setPending();
    ret.?[0] = step.result;
}

fn testStepDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {
    TestLog.drops += 1;
}

fn testSlotDrop(_: [*]u8, _: [*]u8, _: *RocOps) callconv(.c) void {
    TestLog.slot_drops += 1;
}

fn testAbort(_: *RocTask) callconv(.c) void {
    TestLog.aborts += 1;
}

fn testRecord(ops: *RocOps, step: TestStep) [*]u8 {
    const record = erased_callable.allocate(&testStepCall, &testStepDrop, @sizeOf(TestStep), ops);
    @as(*align(1) TestStep, @ptrCast(erased_callable.capturePtr(record))).* = step;
    return record;
}

const test_buffers = BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

test "the pending flag starts clear and is set by setPending" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    var root: [1]u8 = undefined;
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 0 }), &root, test_buffers);
    try std.testing.expect(task.ready());
    task.setPending();
    try std.testing.expect(!task.ready());
    task.pending = 0;
    try std.testing.expectEqual(Status.done, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a resume runs an unwind's records innermost first, the outermost into the root's result" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // The start record (1) pauses after saving 2 (innermost) then 3; on
    // resume 2 runs, then 3, which writes the root's result.
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    const outer = testRecord(ops, .{ .id = 3, .saves = .{ null, null }, .pauses = false, .result = 30 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 10 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 2), task.len);
    task.wake();
    try std.testing.expectEqual(Status.done, task.resumeTask());

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(?[*]u8, task.result_buffer), TestLog.results_written_to[1]);
    try std.testing.expectEqual(@as(?[*]u8, &root), TestLog.results_written_to[2]);
    try std.testing.expectEqual(@as(u8, 30), root[0]);
    try std.testing.expectEqual(@as(usize, 3), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "records a resumed record saves go before the records still waiting" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // 1 saves 2 then 9 and pauses. Resumed, 2 saves 4 then 5 and pauses
    // again, so the list runs 4, 5, then 9.
    const nested_inner = testRecord(ops, .{ .id = 4, .saves = .{ null, null }, .pauses = false, .result = 0 });
    const nested_outer = testRecord(ops, .{ .id = 5, .saves = .{ null, null }, .pauses = false, .result = 0 });
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ nested_inner, nested_outer }, .pauses = true, .result = 0 });
    const outer = testRecord(ops, .{ .id = 9, .saves = .{ null, null }, .pauses = false, .result = 90 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake();
    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake();
    try std.testing.expectEqual(Status.done, task.resumeTask());

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 4, 5, 9 }, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(u8, 90), root[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "cancelling a parked task aborts its operation and releases every record" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 });
    const outer = testRecord(ops, .{ .id = 3, .saves = .{ null, null }, .pauses = false, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.cancel(&testAbort);
    try std.testing.expectEqual(@as(usize, 1), TestLog.aborts);
    try std.testing.expectEqual(@as(usize, 0), TestLog.slot_drops);
    try std.testing.expectEqual(@as(usize, 3), TestLog.drops);
    try std.testing.expectEqualSlices(u8, &.{1}, TestLog.calls[0..TestLog.call_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "cancelling a woken task releases the hosted result instead of aborting" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, null }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake();
    task.cancel(&testAbort);
    try std.testing.expectEqual(@as(usize, 0), TestLog.aborts);
    try std.testing.expectEqual(@as(usize, 1), TestLog.slot_drops);
    try std.testing.expectEqual(@as(usize, 2), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "the host's C calls resume, wake and free a task and report its status as a C enum" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, null }, .pauses = true, .result = 10 }), &root, test_buffers);

    try std.testing.expectEqual(@as(u32, 0), host_calls.resumeTask(task));
    host_calls.wake(task);
    try std.testing.expectEqual(@as(u32, 1), host_calls.resumeTask(task));
    try std.testing.expectEqual(@as(u8, 20), root[0]);
    host_calls.free(task);
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "FieldOffsets is where RocTask keeps its first three fields, scaled by the pointer size" {
    const native = FieldOffsets.forPointerSize(@sizeOf(usize));
    try std.testing.expectEqual(@as(usize, native.pending), @offsetOf(RocTask, "pending"));
    try std.testing.expectEqual(@as(usize, native.hosted_slot), @offsetOf(RocTask, "hosted_slot"));
    try std.testing.expectEqual(@as(usize, native.result_buffer), @offsetOf(RocTask, "result_buffer"));
    try std.testing.expectEqual(FieldOffsets{ .pending = 0, .hosted_slot = 4, .result_buffer = 8 }, FieldOffsets.forPointerSize(4));
}

test "compiled code's task builtins create a task with the entered ops and push records onto its list" {
    const dev_wrappers = @import("dev_wrappers.zig");
    const in_process_host = @import("in_process_host.zig");
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    const saved_host = in_process_host.enter(ops, null);
    defer in_process_host.leave(saved_host);
    TestLog.reset();

    var root: [1]u8 = .{0};
    const start = testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 10 });
    const task = dev_wrappers.roc_builtins_task_create(start, &root, 16, 8, 24, 8);
    try std.testing.expectEqual(ops, task.ops);
    try std.testing.expectEqual(@as(usize, 16), task.hosted_slot_size);
    try std.testing.expectEqual(@as(usize, 24), task.result_buffer_size);
    try std.testing.expectEqual(@as(usize, 1), task.len);
    try std.testing.expectEqual(start, task.entries[0].record);

    const record = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    dev_wrappers.roc_builtins_task_push_record(task, record, &testSlotDrop);
    try std.testing.expectEqual(@as(usize, 2), task.len);
    try std.testing.expectEqual(record, task.entries[1].record);
    try std.testing.expectEqual(@as(?SlotDropFn, &testSlotDrop), task.entries[1].slot_drop);

    // Parked and never resumed: cancelling releases both records.
    task.setPending();
    task.cancel(&testAbort);
    try std.testing.expectEqual(@as(usize, 2), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

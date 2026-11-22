//! The pausing programs of `task_ops_lir_test.zig`, compiled by the wasm
//! backend into a module that exports the task entry and the host's task
//! calls, and run in bytebox against a pausing host (design.md "Backends"):
//! the same outcomes as the interpreter's, from records compiled code packs
//! inside wasm memory.
//!
//! A task is cancelled through the module's own `roc_task_cancel`, which
//! calls the host's `roc_task_abort` (design.md "Backends").

const std = @import("std");
const builtins = @import("builtins");
const backend = @import("backend");
const eval = @import("eval");
const lir = @import("lir");
const lir_test = @import("task_ops_lir_test.zig");

const LIR = lir.LIR;
const Fixture = lir_test.Fixture;
const wasm_runner = eval.wasm_runner;
const Session = wasm_runner.Session;
const Val = wasm_runner.Val;
const WasmCodeGen = backend.wasm.WasmCodeGen;
const Status = builtins.task.Status;
const shim_symbols = builtins.shim_symbols;

const WasmTaskTestError = lir_test.TaskOpsTestError || WasmCodeGen.HostedSymbolError || wasm_runner.WasmOutcomeError;

/// What the pausing host saw at its one suspending hosted call, which the
/// module imports as `roc_test_pause`: `u32 f(RocTask *task, T *out, u64 x)`
/// after the continuation pass. Pending: the host writes the slot and wakes
/// the task later. Addresses are wasm32 linear-memory addresses.
const PausingHost = struct {
    calls: u32 = 0,
    task: u32 = 0,
    slot: u32 = 0,
    x: u64 = 0,
    /// The task the last `roc_task_abort` was given.
    aborted: u32 = 0,
    aborts: u32 = 0,

    fn pause(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const Val, results: [*]Val) error{}!void {
        const self: *PausingHost = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.task = @bitCast(params[0].I32);
        self.slot = @bitCast(params[1].I32);
        self.x = @bitCast(params[2].I64);
        results[0] = .{ .I32 = 1 };
    }

    /// `void roc_task_abort(RocTask *task)`.
    fn abort(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const Val, _: [*]Val) error{}!void {
        const self: *PausingHost = @ptrCast(@alignCast(context));
        self.aborts += 1;
        self.aborted = @bitCast(params[0].I32);
    }
};

/// `f`'s program compiled by the wasm backend and instantiated, with the
/// task entry `roc_task_entry(x, result_out)` exported beside the host's
/// task calls.
const WasmRun = struct {
    host: PausingHost,
    session: Session,

    fn init(self: *WasmRun, f: *Fixture, entry: LIR.LirProcSpecId) WasmTaskTestError!void {
        self.host = .{};
        // Code generation takes LIR after ARC, which the pipeline runs after
        // the continuation pass, with the task entry as a root.
        _ = try lir.Arc.insert(&f.store, &f.layouts, .{ .roots = &.{entry} });
        var codegen = WasmCodeGen.init(f.allocator, &f.store, &f.layouts, .default);
        defer codegen.deinit();
        const objects = eval.InspectedRun.wasmRuntimeObjects(.default);
        const module = try codegen.generateEntrypointModule(
            &.{.{ .symbol_name = "roc_task_entry", .proc = entry, .arg_layouts = &.{ .u64, .opaque_ptr }, .ret_layout = .opaque_ptr }},
            &.{ shim_symbols.roc_task_resume, shim_symbols.roc_task_wake, shim_symbols.roc_task_free },
            objects.builtins,
            objects.boxy_runtime,
        );
        defer f.allocator.free(module.wasm_bytes);
        try self.session.init(f.allocator, module.wasm_bytes, module.heap_base, &.{ .{
            .name = "roc_test_pause",
            .params = &.{ .I32, .I32, .I64 },
            .results = &.{.I32},
            .callback = PausingHost.pause,
            .context = &self.host,
        }, .{
            .name = shim_symbols.roc_task_abort,
            .params = &.{.I32},
            .results = &.{},
            .callback = PausingHost.abort,
            .context = &self.host,
        } });
    }

    fn deinit(self: *WasmRun) void {
        self.session.deinit();
    }

    /// Call the task entry as the host calls a provides entry, with 20 and
    /// the root result's address, and return the task it creates.
    fn start(self: *WasmRun, root: u32) WasmTaskTestError!u32 {
        var task: [1]Val = undefined;
        try self.session.invoke("roc_task_entry", &.{ .{ .I64 = 20 }, .{ .I32 = @bitCast(root) } }, &task);
        return @bitCast(task[0].I32);
    }

    fn resumeTask(self: *WasmRun, task: u32) WasmTaskTestError!Status {
        var status: [1]Val = undefined;
        try self.session.invoke(shim_symbols.roc_task_resume, &.{.{ .I32 = @bitCast(task) }}, &status);
        return @fromBackingInt(@intCast(status[0].I32));
    }

    fn call(self: *WasmRun, name: []const u8, task: u32) WasmTaskTestError!void {
        try self.session.invoke(name, &.{.{ .I32 = @bitCast(task) }}, &.{});
    }
};

test "a task paused at a hosted call resumes from its record and returns the root result on the wasm backend" {
    var f = try Fixture.initFor(std.testing.allocator, .u32);
    defer f.deinit();
    const entry = try lir_test.pausingProgram(&f, .u64, true);
    var run: WasmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    const root = run.session.alloc(8, 8);
    const task = try run.start(root);

    // The first run reaches the hosted call, which is pending: the task
    // parks with g's record saved.
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u32, 1), run.host.calls);
    try std.testing.expectEqual(task, run.host.task);
    try std.testing.expectEqual(@as(u64, 20), run.host.x);

    // The host finishes: it writes the result and wakes the task, which
    // resumes in g's continuation with x restored from the record.
    std.mem.writeInt(u64, run.session.memory()[run.host.slot..][0..8], 22, .little);
    try run.call(shim_symbols.roc_task_wake, task);
    try std.testing.expectEqual(Status.done, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, run.session.memory()[root..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 1), run.host.calls);
    try run.call(shim_symbols.roc_task_free, task);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

test "a task paused inside a called procedure resumes in its caller's continuation on the wasm backend" {
    var f = try Fixture.initFor(std.testing.allocator, .u32);
    defer f.deinit();
    const entry = try lir_test.pausingNestedProgram(&f);
    var run: WasmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    const root = run.session.alloc(8, 8);
    const task = try run.start(root);

    // k saves its record at the hosted call; g reads the pending flag with
    // task_ready after k returns and saves its own record.
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u64, 20), run.host.x);
    std.mem.writeInt(u64, run.session.memory()[run.host.slot..][0..8], 22, .little);
    try run.call(shim_symbols.roc_task_wake, task);
    try std.testing.expectEqual(Status.done, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, run.session.memory()[root..][0..8], .little));
    try std.testing.expectEqual(@as(u32, 1), run.host.calls);
    try run.call(shim_symbols.roc_task_free, task);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

test "a task whose hosted result has a slot release resumes and releases that result on the wasm backend" {
    var f = try Fixture.initFor(std.testing.allocator, .u32);
    defer f.deinit();
    // The hosted result is a string, so its site's record names a slot
    // release, and the module carries that release's adapter.
    const entry = try lir_test.pausingProgram(&f, .str, false);
    var run: WasmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    const root = run.session.alloc(8, 8);
    const task = try run.start(root);
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));

    // The host writes a small wasm32 string, the text then its length with
    // the small-string flag in the final byte, and wakes the task. g's
    // continuation drops it and returns x.
    const text = "paused";
    const str_size = builtins.str.RocStr.word_count * 4;
    const slot = run.session.memory()[run.host.slot..][0..str_size];
    @memset(slot, 0);
    @memcpy(slot[0..text.len], text);
    slot[builtins.str.RocStr.targetFlagByteOffset(4)] = builtins.str.RocStr.small_str_flag | text.len;
    try run.call(shim_symbols.roc_task_wake, task);
    try std.testing.expectEqual(Status.done, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u64, 20), std.mem.readInt(u64, run.session.memory()[root..][0..8], .little));
    try run.call(shim_symbols.roc_task_free, task);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

/// Write a heap wasm32 `Str` holding `text` into `slot`, allocated as Roc
/// allocates one, with its refcount of one before its bytes.
fn writeHeapStr(run: *WasmRun, slot: u32, text: []const u8) void {
    const len: u32 = @intCast(text.len);
    const data = run.session.alloc(4, 4 + len);
    const mem = run.session.memory();
    std.mem.writeInt(u32, mem[data..][0..4], 1, .little);
    @memcpy(mem[data + 4 ..][0..len], text);
    std.mem.writeInt(u32, mem[slot..][0..4], data + 4, .little);
    std.mem.writeInt(u32, mem[slot + 4 ..][0..4], len << builtins.str.RocStr.capacity_shift, .little);
    std.mem.writeInt(u32, mem[slot + 8 ..][0..4], len, .little);
}

test "cancelling a woken task releases the hosted result through its slot release on the wasm backend" {
    var f = try Fixture.initFor(std.testing.allocator, .u32);
    defer f.deinit();
    const entry = try lir_test.pausingProgram(&f, .str, false);
    var run: WasmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    const root = run.session.alloc(8, 8);
    const task = try run.start(root);
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));

    // The host writes a heap string and wakes the task, which is then
    // cancelled instead of resumed: the record's slot release, the module's
    // adapter, frees the string, and no abort runs.
    writeHeapStr(&run, run.host.slot, "a string too long to be small");
    try run.call(shim_symbols.roc_task_wake, task);
    try run.call(shim_symbols.roc_task_cancel, task);
    try std.testing.expectEqual(@as(u32, 0), run.host.aborts);
    try run.call(shim_symbols.roc_task_free, task);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

test "cancelling a task the host has not finished aborts the host call on the wasm backend" {
    var f = try Fixture.initFor(std.testing.allocator, .u32);
    defer f.deinit();
    const entry = try lir_test.pausingProgram(&f, .str, false);
    var run: WasmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    const root = run.session.alloc(8, 8);
    const task = try run.start(root);
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));

    try run.call(shim_symbols.roc_task_cancel, task);
    try std.testing.expectEqual(@as(u32, 1), run.host.aborts);
    try std.testing.expectEqual(task, run.host.aborted);
    try run.call(shim_symbols.roc_task_free, task);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

test "a continuation that pauses again resumes from its own record and finishes on the wasm backend" {
    var f = try Fixture.initFor(std.testing.allocator, .u32);
    defer f.deinit();
    const entry = try lir_test.pausingTwiceProgram(&f);
    var run: WasmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    const root = run.session.alloc(8, 8);
    const task = try run.start(root);
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u64, 20), run.host.x);

    // The first site's continuation runs with x from its record and the
    // host's 22, and pauses at the second site, saving its own record.
    std.mem.writeInt(u64, run.session.memory()[run.host.slot..][0..8], 22, .little);
    try run.call(shim_symbols.roc_task_wake, task);
    try std.testing.expectEqual(Status.pending, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u32, 2), run.host.calls);
    try std.testing.expectEqual(@as(u64, 22), run.host.x);

    std.mem.writeInt(u64, run.session.memory()[run.host.slot..][0..8], 100, .little);
    try run.call(shim_symbols.roc_task_wake, task);
    try std.testing.expectEqual(Status.done, try run.resumeTask(task));
    try std.testing.expectEqual(@as(u64, 120), std.mem.readInt(u64, run.session.memory()[root..][0..8], .little));
    try run.call(shim_symbols.roc_task_free, task);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

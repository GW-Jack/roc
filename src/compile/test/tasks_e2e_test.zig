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
//!
//! The same runs go through the LLVM and dev backends, loaded in this
//! process, with the host's C-ABI hosted functions (design.md "Backends"),
//! and through the wasm backend, in bytebox, with a host that keeps its
//! strings in the module's memory.

const std = @import("std");
const lir = @import("lir");
const eval = @import("eval");
const builtins = @import("builtins");

const harness = @import("lower_to_lir_harness.zig");
const static_data = @import("static_data");
const task_test_host = @import("task_test_host.zig");

const RocStr = builtins.str.RocStr;
const WasmCodeGen = @import("backend").wasm.WasmCodeGen;
const wasm_runner = eval.wasm_runner;
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
    const Program = *const lir.CheckedPipeline.LoweredProgram;

    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    static_data: ?eval.InterpreterStaticData,
    static_strings: eval.LirInterpreter.StaticStrings.Table,
    interpreter: eval.LirInterpreter,

    fn init(self: *Run, lowered: Program, mode: task_test_host.Mode) E2eError!void {
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
    fn startRoot(self: *Run, lowered: Program, result: *RocStr) E2eError!*RocTask {
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

/// The program compiled by the LLVM backend and loaded in this process, its
/// hosted symbols bound to the test host's C-ABI functions.
const LlvmProgram = struct {
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    static_data: []static_data.StaticDataExport,
    image: eval.InspectedRun.LlvmImage,

    fn init(self: *LlvmProgram, lowered: *const lir.CheckedPipeline.LoweredProgram) eval.InspectedRun.LlvmError!void {
        self.lowered = lowered;
        self.static_data = try harness.nativeStaticData(lowered);
        errdefer harness.freeNativeStaticData(self.static_data);
        const program = &lowered.lir_result;
        self.image = try eval.InspectedRun.LlvmImage.load(std.testing.allocator, .{
            .store = &program.store,
            .layouts = &program.layouts,
            .erased_capture_prefix = program.erased_capture_prefix,
            .main_proc = program.root_procs.items[0],
            .static_data = self.static_data,
            .static_data_value_count = program.static_data_values.items.len,
        }, .{ .resolve = task_test_host.resolveCAbiSymbol });
    }

    fn deinit(self: *LlvmProgram) void {
        self.image.deinit();
        harness.freeNativeStaticData(self.static_data);
    }
};

/// One run of the LLVM-compiled program, in this process: the runtime's ops
/// are entered for the builtins, and the test host serves the C-ABI hosted
/// calls.
const LlvmRun = struct {
    const Program = *const LlvmProgram;

    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    entered: builtins.in_process_host.Saved,

    fn init(self: *LlvmRun, _: Program, mode: task_test_host.Mode) E2eError!void {
        self.runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
        const ops = self.runtime.get_ops();
        self.host = TestHost.init(std.testing.allocator, ops, mode);
        self.entered = builtins.in_process_host.enter(ops, null);
        self.host.enterCAbi();
        task_test_host.c_abi_failure = null;
    }

    fn deinit(self: *LlvmRun) void {
        self.host.leaveCAbi();
        builtins.in_process_host.leave(self.entered);
        self.host.deinit();
        self.runtime.deinit();
    }

    /// Make the root's task by calling the compiled task entry
    /// `E(url, result_out)` through its entrypoint wrapper.
    fn startRoot(self: *LlvmRun, program: Program, result: *RocStr) E2eError!*RocTask {
        const store = &program.lowered.lir_result.store;
        const entry = store.getProcSpec(program.lowered.lir_result.root_procs.items[0]);
        try std.testing.expectEqual(@import("layout").Idx.opaque_ptr, entry.ret_layout);
        const ops = self.runtime.get_ops();
        const url_str = RocStr.fromSlice(url, ops);
        var entry_args = EntryArgs{ .url = url_str, .result_out = result };
        var task: *RocTask = undefined;
        const call = program.image.entry() catch return error.TestUnexpectedResult;
        call(@ptrCast(&task), @ptrCast(&entry_args));
        if (task_test_host.c_abi_failure) |err| return err;
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) url_str.decref(ops);
        return task;
    }
};

/// The program compiled by the dev backend into this process, its hosted
/// symbols bound to the test host's C-ABI functions.
const DevProgram = struct {
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    static_data: []static_data.StaticDataExport,
    image: eval.InspectedRun.DevImage,

    fn init(self: *DevProgram, lowered: *const lir.CheckedPipeline.LoweredProgram) eval.InspectedRun.DevError!void {
        self.lowered = lowered;
        self.static_data = try harness.nativeStaticData(lowered);
        errdefer harness.freeNativeStaticData(self.static_data);
        const program = &lowered.lir_result;
        const resolver_context: u8 = 0;
        self.image = try eval.InspectedRun.DevImage.load(std.testing.allocator, .{
            .store = &program.store,
            .layouts = &program.layouts,
            .erased_capture_prefix = program.erased_capture_prefix,
            .main_proc = program.root_procs.items[0],
            .static_data = self.static_data,
            .static_data_value_count = program.static_data_values.items.len,
        }, .{ .context = &resolver_context, .resolve = resolveHostedSymbol });
    }

    fn deinit(self: *DevProgram) void {
        self.image.deinit();
        harness.freeNativeStaticData(self.static_data);
    }

    fn resolveHostedSymbol(_: *const anyopaque, name: []const u8) ?usize {
        return task_test_host.resolveCAbiSymbol(null, name);
    }
};

/// One run of the dev-compiled program, in this process, set up as an LLVM
/// run is.
const DevRun = struct {
    const Program = *const DevProgram;

    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    entered: builtins.in_process_host.Saved,

    fn init(self: *DevRun, _: Program, mode: task_test_host.Mode) E2eError!void {
        self.runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
        const ops = self.runtime.get_ops();
        self.host = TestHost.init(std.testing.allocator, ops, mode);
        self.entered = builtins.in_process_host.enter(ops, null);
        self.host.enterCAbi();
        task_test_host.c_abi_failure = null;
    }

    fn deinit(self: *DevRun) void {
        self.host.leaveCAbi();
        builtins.in_process_host.leave(self.entered);
        self.host.deinit();
        self.runtime.deinit();
    }

    /// Make the root's task by calling the compiled task entry
    /// `E(url, result_out)` through its entrypoint wrapper.
    fn startRoot(self: *DevRun, program: Program, result: *RocStr) E2eError!*RocTask {
        const store = &program.lowered.lir_result.store;
        const entry = store.getProcSpec(program.lowered.lir_result.root_procs.items[0]);
        try std.testing.expectEqual(@import("layout").Idx.opaque_ptr, entry.ret_layout);
        const ops = self.runtime.get_ops();
        const url_str = RocStr.fromSlice(url, ops);
        var entry_args = EntryArgs{ .url = url_str, .result_out = result };
        var task: *RocTask = undefined;
        program.image.entry()(@ptrCast(&task), @ptrCast(&entry_args));
        if (task_test_host.c_abi_failure) |err| return err;
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) url_str.decref(ops);
        return task;
    }
};

/// The program compiled by the wasm backend for wasm32 into one module that
/// exports the task entry beside the merged builtins' task calls, as a
/// wasm host links them (design.md "Backends").
const WasmProgram = struct {
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    module: WasmCodeGen.EntrypointModule,

    fn init(self: *WasmProgram, lowered: *const lir.CheckedPipeline.LoweredProgram) eval.InspectedRun.WasmError!void {
        self.lowered = lowered;
        const data = try harness.nativeStaticData(lowered);
        defer harness.freeNativeStaticData(data);
        const program = &lowered.lir_result;
        const root = program.root_procs.items[0];
        self.module = try eval.InspectedRun.generateWasmEntrypointModule(std.testing.allocator, .{
            .store = &program.store,
            .layouts = &program.layouts,
            .erased_capture_prefix = program.erased_capture_prefix,
            .main_proc = root,
            .static_data = data,
            .static_data_value_count = program.static_data_values.items.len,
        }, &.{.{ .symbol_name = wasm_entry, .proc = root, .arg_layouts = &.{ .str, .opaque_ptr }, .ret_layout = .opaque_ptr }}, &task_calls, .default);
    }

    fn deinit(self: *WasmProgram) void {
        std.testing.allocator.free(self.module.wasm_bytes);
    }
};

/// The export the wasm module gives the task entry.
const wasm_entry = "roc_task_entry";
const task_calls = [_][]const u8{ builtins.shim_symbols.roc_task_resume, builtins.shim_symbols.roc_task_wake, builtins.shim_symbols.roc_task_free };

/// The size of a wasm32 `Str`, and the tag a seamless slice's allocation
/// pointer carries.
const wasm_str_size = builtins.str.RocStr.word_count * 4;
const wasm_slice_tag = 1;

/// The test host for the wasm-compiled program: `TestHost`'s behaviour over
/// the module's linear memory, where its strings live. Its hosted functions
/// are the module's `env` imports, with wasm32's C ABI: a `Str` argument is
/// the address of a copy the callee owns.
const WasmRun = struct {
    const Program = *const WasmProgram;

    session: wasm_runner.Session,
    mode: task_test_host.Mode,
    trace: std.ArrayList([]u8) = .empty,
    /// The paused operation: the task, its result slot, and its URL.
    pending: ?struct { task: u32, out: u32, url: [wasm_str_size]u8 } = null,
    pauses: u32 = 0,
    /// The first error a hosted call hit, which it cannot return.
    failure: ?E2eError = null,

    fn init(self: *WasmRun, program: Program, mode: task_test_host.Mode) E2eError!void {
        self.* = .{ .session = undefined, .mode = mode };
        const fetch_params = [_]wasm_runner.ValType{ .I32, .I32, .I32 };
        const log_params = [_]wasm_runner.ValType{.I32};
        self.session.init(std.testing.allocator, program.module.wasm_bytes, program.module.heap_base, &.{
            .{ .name = "roc_host_fetch", .params = &fetch_params, .results = &.{.I32}, .callback = fetch, .context = self },
            .{ .name = "roc_host_log", .params = &log_params, .results = &.{}, .callback = log, .context = self },
        }) catch return error.TestUnexpectedResult;
    }

    fn deinit(self: *WasmRun) void {
        for (self.trace.items) |entry| std.testing.allocator.free(entry);
        self.trace.deinit(std.testing.allocator);
        self.session.deinit();
    }

    fn mem(self: *WasmRun) []u8 {
        return self.session.memory();
    }

    fn readWord(self: *WasmRun, addr: u32) u32 {
        return std.mem.readInt(u32, self.mem()[addr..][0..4], .little);
    }

    fn writeWord(self: *WasmRun, addr: u32, value: u32) void {
        std.mem.writeInt(u32, self.mem()[addr..][0..4], value, .little);
    }

    /// A heap `Str` holding `text`, allocated as Roc allocates one: its
    /// refcount of one in the word before its bytes.
    fn newStr(self: *WasmRun, text: []const u8, at: u32) void {
        std.debug.assert(text.len > wasm_str_size - 1);
        const len: u32 = @intCast(text.len);
        const data = self.session.alloc(4, 4 + len);
        self.writeWord(data, 1);
        @memcpy(self.mem()[data + 4 ..][0..len], text);
        self.writeWord(at, data + 4);
        self.writeWord(at + 4, len << builtins.str.RocStr.capacity_shift);
        self.writeWord(at + 8, len);
    }

    /// Release the `Str` at `at`, as `RocStr.decref` does.
    fn decrefStr(self: *WasmRun, at: u32) void {
        if (self.mem()[at + wasm_str_size - 1] & builtins.str.RocStr.small_str_flag != 0) return;
        const cap = self.readWord(at + 4);
        const alloc = if (cap & wasm_slice_tag != 0) cap & ~@as(u32, wasm_slice_tag) else self.readWord(at);
        const count = self.readWord(alloc - 4);
        switch (count) {
            0 => {},
            1 => {
                self.writeWord(alloc - 4, 0);
                self.session.free();
            },
            else => self.writeWord(alloc - 4, count - 1),
        }
    }

    fn note(self: *WasmRun, name: []const u8, str_addr: u32) E2eError!void {
        const text = wasm_runner.readWasmStr(self.mem(), str_addr) catch return error.TestUnexpectedResult;
        const entry = try std.fmt.allocPrint(std.testing.allocator, "{s}({s})", .{ name, text });
        errdefer std.testing.allocator.free(entry);
        try self.trace.append(std.testing.allocator, entry);
    }

    fn answer(self: *WasmRun, url_addr: u32, out: u32) E2eError!void {
        const url_text = wasm_runner.readWasmStr(self.mem(), url_addr) catch return error.TestUnexpectedResult;
        const text = try std.fmt.allocPrint(std.testing.allocator, "{s}/body", .{url_text});
        defer std.testing.allocator.free(text);
        self.newStr(text, out);
    }

    /// `u32 roc_host_fetch(RocTask *task, RocStr *out, RocStr *url)`.
    fn fetch(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const wasm_runner.Val, results: [*]wasm_runner.Val) error{}!void {
        const self: *WasmRun = @ptrCast(@alignCast(context));
        const task: u32 = @bitCast(params[0].I32);
        const out: u32 = @bitCast(params[1].I32);
        const url_addr: u32 = @bitCast(params[2].I32);
        results[0] = .{ .I32 = 0 };
        self.fetchOrFail(task, out, url_addr, &results[0]) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn fetchOrFail(self: *WasmRun, task: u32, out: u32, url_addr: u32, poll: *wasm_runner.Val) E2eError!void {
        try self.note("fetch", url_addr);
        switch (self.mode) {
            .ready => {
                try self.answer(url_addr, out);
                self.decrefStr(url_addr);
            },
            .pause => {
                // A task waits on at most one hosted operation at a time.
                if (self.pending != null) return error.TestUnexpectedResult;
                self.pending = .{ .task = task, .out = out, .url = self.mem()[url_addr..][0..wasm_str_size].* };
                self.pauses += 1;
                poll.* = .{ .I32 = 1 };
            },
        }
    }

    /// `void roc_host_log(RocStr *text)`.
    fn log(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const wasm_runner.Val, _: [*]wasm_runner.Val) error{}!void {
        const self: *WasmRun = @ptrCast(@alignCast(context));
        const text: u32 = @bitCast(params[0].I32);
        self.note("log", text) catch |err| {
            if (self.failure == null) self.failure = err;
        };
        self.decrefStr(text);
    }

    fn call(self: *WasmRun, name: []const u8, task: u32, returns: []wasm_runner.Val) E2eError!void {
        self.session.invoke(name, &.{.{ .I32 = @bitCast(task) }}, returns) catch return error.TestUnexpectedResult;
        if (self.failure) |err| return err;
    }

    fn resumeTask(self: *WasmRun, task: u32) E2eError!builtins.task.Status {
        var status: [1]wasm_runner.Val = undefined;
        try self.call(builtins.shim_symbols.roc_task_resume, task, &status);
        return @fromBackingInt(@intCast(status[0].I32));
    }

    /// Finish the paused operation: write its result and wake its task.
    fn finish(self: *WasmRun) E2eError!void {
        const pending = self.pending.?;
        self.pending = null;
        // The URL goes back into memory the host owns while it answers.
        const url_addr = self.session.alloc(4, wasm_str_size);
        self.mem()[url_addr..][0..wasm_str_size].* = pending.url;
        try self.answer(url_addr, pending.out);
        self.decrefStr(url_addr);
        self.session.free();
        try self.call(builtins.shim_symbols.roc_task_wake, pending.task, &.{});
    }

    /// Run the task to its end, as `TestHost.drive` does.
    fn drive(self: *WasmRun, task: u32) E2eError!builtins.task.Status {
        var status = try self.resumeTask(task);
        while (status == .pending) {
            try self.finish();
            status = try self.resumeTask(task);
        }
        return status;
    }
};

/// Run the wasm-compiled program to its end with a host in `mode`: the same
/// result, trace, and pauses as the interpreter's, and nothing live after.
/// Cancelling a parked task needs `roc_task_cancel`, which joins the host
/// ABI with `roc_task_abort` (design.md "Host Contract"), so the wasm runs
/// do not cancel.
fn runToEndWasm(program: *const WasmProgram, mode: task_test_host.Mode) E2eError!void {
    var run: WasmRun = undefined;
    try run.init(program, mode);
    defer run.deinit();
    const store = &program.lowered.lir_result.store;
    const entry = store.getProcSpec(program.lowered.lir_result.root_procs.items[0]);
    // The host's own memory for the URL argument and the root's result.
    const url_addr = run.session.alloc(4, wasm_str_size);
    const result = run.session.alloc(4, wasm_str_size);
    @memset(run.mem()[result..][0..wasm_str_size], 0);
    run.newStr(url, url_addr);
    var task: [1]wasm_runner.Val = undefined;
    run.session.invoke(wasm_entry, &.{ .{ .I32 = @bitCast(url_addr) }, .{ .I32 = @bitCast(result) } }, &task) catch return error.TestUnexpectedResult;
    if (run.failure) |err| return err;
    // A borrowed argument stays the caller's.
    if ((entry.rc_borrowed_params & 1) != 0) run.decrefStr(url_addr);
    run.session.free();
    const task_addr: u32 = @bitCast(task[0].I32);
    try std.testing.expectEqual(builtins.task.Status.done, try run.drive(task_addr));
    try run.call(builtins.shim_symbols.roc_task_free, task_addr, &.{});
    const got = wasm_runner.readWasmStr(run.mem(), result) catch return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected_result, got);
    run.decrefStr(result);
    run.session.free();
    try std.testing.expectEqual(expected_trace.len, run.trace.items.len);
    for (expected_trace, run.trace.items) |want, got_entry| try std.testing.expectEqualStrings(want, got_entry);
    try std.testing.expectEqual(@as(u32, if (mode == .pause) pause_count else 0), run.pauses);
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

fn runAllWasm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: WasmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the Tasks program with the wasm backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    for ([_]task_test_host.Mode{ .ready, .pause }) |mode| {
        runToEndWasm(&program, mode) catch |err| {
            std.log.err("tasks end-to-end run on wasm ({s}) failed: {s}", .{ @tagName(mode), @errorName(err) });
            return error.TestUnexpectedResult;
        };
    }
}

/// The task entry's arguments, laid out as the entrypoint ABI lays them out.
const EntryArgs = extern struct { url: RocStr, result_out: *RocStr };

fn expectTrace(host: *const TestHost) E2eError!void {
    try std.testing.expectEqual(expected_trace.len, host.trace.items.len);
    for (expected_trace, host.trace.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn runToEnd(comptime R: type, program: R.Program, mode: task_test_host.Mode) E2eError!void {
    var run: R = undefined;
    try run.init(program, mode);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    try std.testing.expectEqual(builtins.task.Status.done, try run.host.drive(task));
    task.free();
    try std.testing.expectEqualStrings(expected_result, result.asSlice());
    result.decref(run.runtime.get_ops());
    try expectTrace(&run.host);
    try std.testing.expectEqual(@as(u32, if (mode == .pause) pause_count else 0), run.host.pauses);
    try run.runtime.checkForLeaks();
}

fn cancelAt(comptime R: type, program: R.Program, pause: u32, woken: bool) E2eError!void {
    var run: R = undefined;
    try run.init(program, .pause);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    try std.testing.expectEqual(builtins.task.Status.cancelled, try run.host.driveAndCancel(task, pause, woken));
    task.free();
    try std.testing.expectEqual(@as(u32, if (woken) 0 else 1), run.host.aborts);
    try run.runtime.checkForLeaks();
}

fn runAll(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    checkAll(Run, lowered) catch |err| {
        std.log.err("tasks end-to-end run failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn checkAll(comptime R: type, program: R.Program) E2eError!void {
    try runToEnd(R, program, .ready);
    try runToEnd(R, program, .pause);
    for (1..pause_count + 1) |pause| {
        for ([_]bool{ false, true }) |woken| try cancelAt(R, program, @intCast(pause), woken);
    }
    if (task_test_host.c_abi_failure) |err| return err;
}

fn runAllLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the Tasks program with LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    // A host links its task calls from the program it runs.
    for ([_][]const u8{ builtins.shim_symbols.roc_task_resume, builtins.shim_symbols.roc_task_wake, builtins.shim_symbols.roc_task_free }) |name| {
        if (program.image.lib.lookup(*const anyopaque, name) == null) {
            std.log.err("the LLVM-compiled Tasks program does not export {s}", .{name});
            return error.TestUnexpectedResult;
        }
    }
    checkAll(LlvmRun, &program) catch |err| {
        std.log.err("tasks end-to-end run on LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn runAllDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the Tasks program with the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    checkAll(DevRun, &program) catch |err| {
        std.log.err("tasks end-to-end run on the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

test "a Tasks program pauses at every suspending call and gives the same result with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAll);
}

test "a Tasks program compiled by LLVM pauses and cancels as it does on the interpreter, with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAllLlvm);
}

test "a Tasks program compiled by the dev backend pauses and cancels as it does on the interpreter, with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAllDev);
}

test "a Tasks program compiled by the wasm backend pauses as it does on the interpreter, with no leaks" {
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u32 }, runAllWasm);
}

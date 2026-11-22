//! wasm32 host for the `concurrency: Tasks` test platform: the native
//! host's pausing loop (host.zig) inside the module, driven from
//! `wasm_main`.
//!
//! `wasm_configure(mode, pause)` picks how the next `wasm_main` runs:
//! - 0: answer every `roc_host_fetch` on the next turn of the loop;
//! - 1: answer every fetch during the call;
//! - 2: cancel at pause `pause` before answering, so the program aborts the
//!   fetch through `roc_task_abort`;
//! - 3: answer and wake at pause `pause`, then cancel, so the program
//!   releases the answer.
//!
//! `wasm_main` returns the text the native host prints (the result or where
//! it cancelled, then the fetch and pause counts), copied out of the heap,
//! so a run that frees everything it allocated leaves `wasm_alloc_count`
//! equal to `wasm_dealloc_count`. The module imports only `roc_panic`,
//! `roc_dbg` and `roc_expect_failed` from `env`.

const std = @import("std");
const builtins = @import("builtins");
const host_alloc = @import("host_alloc");

const shim_symbols = builtins.shim_symbols;
const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;
const TaskStatus = builtins.task.Status;

const env_imports = struct {
    extern "env" fn roc_panic(ptr: [*]const u8, len: usize) noreturn;
    extern "env" fn roc_dbg(ptr: [*]const u8, len: usize) void;
    extern "env" fn roc_expect_failed(ptr: [*]const u8, len: usize) void;
};

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    env_imports.roc_panic(msg.ptr, msg.len);
}

const wasm_allocator = std.heap.wasm_allocator;

/// Allocations and deallocations served, by the program and by the host.
var alloc_counts: [2]usize = .{ 0, 0 };

comptime {
    shim_symbols.exportRuntimeFns(.{
        .alloc = &rocAlloc,
        .dealloc = &rocDealloc,
        .realloc = &rocRealloc,
        .dbg = &rocDbg,
        .expect_failed = &rocExpectFailed,
        .crashed = &rocCrashed,
    }, .default);
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    alloc_counts[0] += 1;
    return host_alloc.alloc(wasm_allocator, length, alignment) orelse @trap();
}

fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    alloc_counts[1] += 1;
    host_alloc.dealloc(wasm_allocator, ptr, alignment);
}

fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    alloc_counts[0] += 1;
    alloc_counts[1] += 1;
    return host_alloc.realloc(wasm_allocator, ptr, new_length, alignment) orelse @trap();
}

fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    env_imports.roc_dbg(bytes, len);
}

fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    env_imports.roc_expect_failed(bytes, len);
}

fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    env_imports.roc_panic(bytes, len);
}

/// The host's own string operations allocate through the same functions.
fn opsAlloc(_: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
    return rocAlloc(length, alignment);
}

fn opsDealloc(_: *RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    rocDealloc(ptr, alignment);
}

fn opsRealloc(_: *RocOps, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    return rocRealloc(ptr, new_length, alignment);
}

fn opsDbg(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    rocDbg(bytes, len);
}

fn opsExpectFailed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    rocExpectFailed(bytes, len);
}

fn opsCrashed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    rocCrashed(bytes, len);
}

var host_env: u8 = 0;

var roc_ops = RocOps{
    .env = @as(*anyopaque, @ptrCast(&host_env)),
    .roc_alloc = opsAlloc,
    .roc_dealloc = opsDealloc,
    .roc_realloc = opsRealloc,
    .roc_dbg = opsDbg,
    .roc_expect_failed = opsExpectFailed,
    .roc_crashed = opsCrashed,
    .hosted_fns = .{ .count = 0, .fns = undefined }, // hosted functions are reached by symbol
};

/// `RocPoll` (design.md "Host Contract").
const poll_ready: u32 = 0;
const poll_pending: u32 = 1;

const Mode = enum(u32) { pause_every_fetch = 0, finish_at_once = 1, cancel_at = 2, cancel_woken_at = 3 };

/// The fetch the task is parked on, answered on the next turn of the loop.
const Pending = struct {
    task: *RocTask,
    out: *RocStr,
    url: RocStr,
};

var mode: Mode = .pause_every_fetch;
var cancel_pause: u32 = 0;
var pending: ?Pending = null;
var fetches: u32 = 0;
var pauses: u32 = 0;

/// The answer to `fetch!(url)`. It owns `url`.
fn answer(url: RocStr) RocStr {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "fetched({s})", .{url.asSlice()}) catch "fetched(...)";
    var owned = url;
    owned.decref(&roc_ops);
    return RocStr.fromSlice(text, &roc_ops);
}

/// `RocPoll roc_host_fetch(RocTask *task, RocStr *out, RocStr url)`.
fn hostedFetch(task: *RocTask, out: *RocStr, url: RocStr) callconv(.c) u32 {
    fetches += 1;
    if (mode == .finish_at_once) {
        out.* = answer(url);
        return poll_ready;
    }
    if (pending != null) @panic("a second fetch while one is pending");
    pending = .{ .task = task, .out = out, .url = url };
    return poll_pending;
}

/// `void roc_task_abort(RocTask *task)`: abandon the fetch the cancelled
/// task is parked on, releasing its URL.
fn taskAbort(task: *RocTask) callconv(.c) void {
    const parked = pending orelse @panic("roc_task_abort with no fetch pending");
    if (parked.task != task) @panic("roc_task_abort for another task");
    pending = null;
    var url = parked.url;
    url.decref(&roc_ops);
}

comptime {
    @export(&hostedFetch, .{ .name = "roc_host_fetch", .visibility = .hidden });
    @export(&taskAbort, .{ .name = shim_symbols.roc_task_abort, .visibility = .hidden });
}

extern fn roc_main(url: RocStr, result_out: *RocStr) callconv(.c) *RocTask;
extern fn roc_task_resume(task: *RocTask) callconv(.c) u32;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;
extern fn roc_task_cancel(task: *RocTask) callconv(.c) void;

var report_buf: [512]u8 = undefined;
var report_len: usize = 0;

fn report(comptime fmt: []const u8, args: anytype) void {
    report_len = (std.fmt.bufPrint(&report_buf, fmt, args) catch @panic("report too long")).len;
}

/// Set how the next `wasm_main` runs; see the module comment.
export fn wasm_configure(new_mode: u32, pause: u32) void {
    mode = std.enums.fromInt(Mode, new_mode) orelse @panic("unknown mode");
    cancel_pause = pause;
}

/// Run the app once and return the address of its report.
export fn wasm_main() [*]const u8 {
    pending = null;
    fetches = 0;
    pauses = 0;
    // Long enough that the string, and the answer built from it, live on the
    // heap and so count toward the allocation balance.
    const url = RocStr.fromSlice("https://example.com/concurrency/tasks", &roc_ops);
    var result: RocStr = undefined;
    const task = roc_main(url, &result);

    while (true) {
        const status = roc_task_resume(task);
        if (status == @backingInt(TaskStatus.done)) break;
        if (status != @backingInt(TaskStatus.pending)) @panic("unexpected task status");
        const parked = pending orelse @panic("the task paused with no fetch pending");
        pauses += 1;
        const cancelling = (mode == .cancel_at or mode == .cancel_woken_at) and pauses == cancel_pause;
        if (!cancelling or mode == .cancel_woken_at) {
            pending = null;
            parked.out.* = answer(parked.url);
            roc_task_wake(parked.task);
        }
        if (cancelling) {
            roc_task_cancel(task);
            roc_task_free(task);
            report("cancelled at pause {d}\nfetches: {d}, pauses: {d}\n", .{ pauses, fetches, pauses });
            return &report_buf;
        }
    }
    roc_task_free(task);
    report("{s}\nfetches: {d}, pauses: {d}\n", .{ result.asSlice(), fetches, pauses });
    result.decref(&roc_ops);
    return &report_buf;
}

/// The length of the last `wasm_main` report.
export fn wasm_result_len() usize {
    return report_len;
}

export fn wasm_alloc_count() usize {
    return alloc_counts[0];
}

export fn wasm_dealloc_count() usize {
    return alloc_counts[1];
}

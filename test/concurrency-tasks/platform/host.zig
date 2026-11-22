//! Host for the `concurrency: Tasks` test platform: a pausing host.
//!
//! It calls `roc_main`, which returns a task, and drives that task with
//! `roc_task_resume`. Every `roc_host_fetch` call parks: the host answers it
//! on the next turn of its loop, writing the result to the call's `out` and
//! waking the task. With `--finish-at-once` it answers every call during the
//! call instead, so the same app runs both ways. With `--cancel-at N` it
//! cancels the task through the program's `roc_task_cancel` at its Nth pause
//! instead of answering, so the program aborts the fetch through the host's
//! `roc_task_abort`; with `--cancel-woken-at N` it answers and wakes the task
//! first, so the program releases the answer. It prints the result, or where
//! it cancelled, and the number of pauses, and fails the run unless every
//! allocation it served was freed.

const std = @import("std");
const shim_io = @import("shim_io");
const builtins = @import("builtins");
const host_alloc = @import("host_alloc");

pub const std_options_elf_debug_info_search_paths = shim_io.elfDebugInfoSearchPaths;
pub const std_options_debug_io = shim_io.io();
pub const std_options_debug_threaded_io = null;
// See `shim_io.std_options_static_archive` for why these settings matter to a
// static archive that roc links into a program.
pub const std_options = shim_io.std_options_static_archive;

const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;
const TaskStatus = builtins.task.Status;

/// `RocPoll` (design.md "Host Contract").
const poll_ready: u32 = 0;
const poll_pending: u32 = 1;

/// Counts the allocations live in the backing allocator, so the host can
/// check that the program freed everything it allocated.
const HostEnv = struct {
    live_allocations: i64 = 0,

    pub fn rocAllocator(_: *HostEnv) std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

const callbacks = host_alloc.Callbacks(HostEnv);

var g_host_env: HostEnv = .{};

fn rocAllocFn(ops: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
    g_host_env.live_allocations += 1;
    return callbacks.rocAllocFn(ops, length, alignment);
}

fn rocDeallocFn(ops: *RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    g_host_env.live_allocations -= 1;
    callbacks.rocDeallocFn(ops, ptr, alignment);
}

var g_roc_ops = RocOps{
    .env = @as(*anyopaque, @ptrCast(&g_host_env)),
    .roc_alloc = rocAllocFn,
    .roc_dealloc = rocDeallocFn,
    .roc_realloc = callbacks.rocReallocFn,
    .roc_dbg = callbacks.rocDbgFn,
    .roc_expect_failed = callbacks.rocExpectFailedFn,
    .roc_crashed = callbacks.rocCrashedFn,
    .hosted_fns = .{ .count = 0, .fns = undefined }, // hosted functions are reached by symbol
};

fn getOps() *RocOps {
    return &g_roc_ops;
}

/// The `fetch!` call the task is parked on, answered on the next turn of the
/// host's loop.
const Pending = struct {
    task: *RocTask,
    out: *RocStr,
    url: RocStr,
};

var g_pending: ?Pending = null;
var g_finish_at_once = false;
/// The pause at which the host cancels the task, if any.
var g_cancel_at: ?u32 = null;
/// Whether the host answers and wakes the task before cancelling it.
var g_cancel_woken = false;
var g_fetches: u32 = 0;
var g_pauses: u32 = 0;

/// The answer to `fetch!(url)`. It owns `url`.
fn answer(url: RocStr) RocStr {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "fetched({s})", .{url.asSlice()}) catch "fetched(...)";
    var owned = url;
    owned.decref(&g_roc_ops);
    return RocStr.fromSlice(text, &g_roc_ops);
}

/// `RocPoll roc_host_fetch(RocTask *task, RocStr *out, RocStr url)`.
fn hostedFetch(task: *RocTask, out: *RocStr, url: RocStr) callconv(.c) u32 {
    g_fetches += 1;
    if (g_finish_at_once) {
        out.* = answer(url);
        return poll_ready;
    }
    // design.md "Host Contract": the host resumes a task only after a resume
    // returns, so one task waits on at most one call.
    std.debug.assert(g_pending == null);
    g_pending = .{ .task = task, .out = out, .url = url };
    return poll_pending;
}

/// `void roc_task_abort(RocTask *task)`, which every `Tasks` host defines
/// (design.md "Host Contract"): abandon the fetch the cancelled task is
/// parked on, releasing its URL.
fn taskAbort(task: *RocTask) callconv(.c) void {
    const pending = g_pending orelse @panic("roc_task_abort with no fetch pending");
    std.debug.assert(pending.task == task);
    g_pending = null;
    var url = pending.url;
    url.decref(&g_roc_ops);
}

comptime {
    @export(&hostedFetch, .{ .name = "roc_host_fetch", .visibility = .hidden });
    @export(&taskAbort, .{ .name = builtins.shim_symbols.roc_task_abort, .visibility = .hidden });
    host_alloc.exportRuntimeSymbols(getOps, .{});
}

extern fn roc_main(url: RocStr, result_out: *RocStr) callconv(.c) *RocTask;
extern fn roc_task_resume(task: *RocTask) callconv(.c) u32;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;
extern fn roc_task_cancel(task: *RocTask) callconv(.c) void;

// OS-specific entry point handling
comptime {
    @export(&main, .{ .name = "main" });
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--finish-at-once")) {
            g_finish_at_once = true;
        } else if (std.mem.eql(u8, arg, "--cancel-at") or std.mem.eql(u8, arg, "--cancel-woken-at")) {
            g_cancel_woken = std.mem.eql(u8, arg, "--cancel-woken-at");
            i += 1;
            const pause = if (i < @as(usize, @intCast(argc))) std.mem.span(argv[i]) else "";
            g_cancel_at = std.fmt.parseInt(u32, pause, 10) catch return usage(arg);
        } else {
            return usage(arg);
        }
    }
    platformMain() catch |err| {
        std.debug.print("HOST ERROR: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn usage(arg: []const u8) c_int {
    std.debug.print("Error: bad argument '{s}'\nUsage: <app> [--finish-at-once | --cancel-at N | --cancel-woken-at N]\n", .{arg});
    return 1;
}

const HostError = error{ TaskCancelled, UnexpectedStatus, Leaked };

fn platformMain() HostError!void {
    // Long enough that the string, and the answer built from it, live on the
    // heap and so count toward the leak check.
    const url = RocStr.fromSlice("https://example.com/concurrency/tasks", &g_roc_ops);
    var result: RocStr = undefined;
    const task = roc_main(url, &result);

    while (true) {
        const status = roc_task_resume(task);
        if (status == @backingInt(TaskStatus.done)) break;
        if (status == @backingInt(TaskStatus.cancelled)) return error.TaskCancelled;
        if (status != @backingInt(TaskStatus.pending)) return error.UnexpectedStatus;
        // The task paused on a fetch: answer it, then resume it.
        const pending = g_pending orelse return error.UnexpectedStatus;
        g_pauses += 1;
        const cancelling = g_cancel_at == g_pauses;
        if (!cancelling or g_cancel_woken) {
            g_pending = null;
            pending.out.* = answer(pending.url);
            roc_task_wake(pending.task);
        }
        if (cancelling) {
            // Unwoken, the program aborts the fetch through `taskAbort`.
            roc_task_cancel(task);
            roc_task_free(task);
            std.debug.print("cancelled at pause {d}\nfetches: {d}, pauses: {d}\n", .{ g_pauses, g_fetches, g_pauses });
            return checkLeaks();
        }
    }
    roc_task_free(task);

    std.debug.print("{s}\nfetches: {d}, pauses: {d}\n", .{ result.asSlice(), g_fetches, g_pauses });
    result.decref(&g_roc_ops);
    return checkLeaks();
}

fn checkLeaks() HostError!void {
    if (g_host_env.live_allocations != 0) {
        std.debug.print("live allocations: {d}\n", .{g_host_env.live_allocations});
        return error.Leaked;
    }
}

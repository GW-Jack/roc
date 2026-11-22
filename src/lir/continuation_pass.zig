//! The continuation pass (design.md "The Continuation Pass").
//!
//! For every procedure that may suspend, this gives the procedure the task
//! as a hidden argument, passes it at every suspension site, and makes a
//! continuation procedure `C(f, k)` and a resume entry `R(f, k)` for every
//! site `k` that is not a tail site. A continuation is a copy of the code
//! after its call, inside copies of the enclosing joins that code can jump
//! to, stopped at every later site by a tail call to that site's
//! continuation. Every occurrence of a site that is not a tail site, in its
//! procedure and in the copies, gets a pending edge that saves the site's
//! resume entry and returns. Each `suspending` hosted procedure takes the
//! host's shape: the task and a result pointer first, a `RocPoll` result.

const std = @import("std");
const builtin = @import("builtin");
const collections = @import("collections");
const core = @import("lir_core");
const layout = @import("layout");
const body_clone = @import("body_clone.zig");
const ContinuationSites = @import("continuation_sites.zig");
const SuspensionMarks = @import("suspension_marks.zig");
const invariant = @import("base").invariant;

const LIR = core.LIR;
const LirStore = core.LirStore;
const GuardedList = LirStore.GuardedList;
const Allocator = std.mem.Allocator;
const CFStmtId = LIR.CFStmtId;
const LocalId = LIR.LocalId;
const ProcId = LIR.LirProcSpecId;

/// The `RocPoll` value a `suspending` hosted procedure returns when it
/// finished; every other value means it is pending (design.md "Host
/// Contract").
const roc_ready: u64 = 0;

/// What the pass knows about one site of the procedure that contains it.
const SiteInfo = struct {
    live_after: []const LocalId,
    /// The call's target in the procedure that contains the site.
    target: LocalId,
    hosted: bool,
    /// The site's continuation and resume entry, or null for a tail site.
    continuation: ?ProcId,
    resume_entry: ?ProcId,
    capture_layout: layout.Idx,
    on_drop: LIR.ErasedCallableOnDrop,
    slot_drop: LIR.ErasedCallableOnDrop,
};

const ProcPlan = struct {
    proc: ProcId,
    sites: ContinuationSites.Sites,
    task: LocalId,
};

/// Give every procedure that may suspend its task argument, make the
/// continuation and resume entry of each of its sites that is not a tail
/// site, add the pending edges, and give `suspending` hosted procedures the
/// host's shape.
pub fn run(allocator: Allocator, store: *LirStore, layouts: *layout.Store) Allocator.Error!void {
    var plans = std.ArrayList(ProcPlan).empty;
    defer {
        for (plans.items) |*plan| plan.sites.deinit();
        plans.deinit(allocator);
    }

    const proc_count = store.procSpecCount();
    for (0..proc_count) |index| {
        const proc_id: ProcId = @fromBackingInt(@intCast(index));
        const proc = store.getProcSpecImmediate(proc_id);
        if (proc.body.get() == null or proc.suspends == .never) continue;
        switch (proc.abi) {
            .roc => {},
            // Its erased callers have no task to pass it (design.md "What
            // Implements It First").
            .erased_callable, .erased_record => std.debug.panic("not yet implemented: an erased callable that may suspend", .{}),
        }
        var sites = try ContinuationSites.analyze(allocator, store, proc_id);
        errdefer sites.deinit();
        try plans.append(allocator, .{ .proc = proc_id, .sites = sites, .task = undefined });
    }
    if (plans.items.len == 0) return;

    // The task: a hidden argument after the explicit ones, passed on at
    // every site to a procedure. A hosted site takes it in the host's
    // shape, which the hosted rewrite builds.
    for (plans.items) |*plan| {
        plan.task = try store.addLocal(.{ .layout_idx = .opaque_ptr });
        try appendLocal(store, &store.getProcSpecPtr(plan.proc).args, plan.task);
        try appendLocal(store, &store.getProcSpecPtr(plan.proc).frame_locals, plan.task);
        for (plan.sites.sites) |site| {
            const call = store.getCFStmtImmediate(site.call).assign_call;
            if (isHosted(store, call.proc)) continue;
            const args = &store.getCFStmtPtr(site.call).assign_call.args;
            try appendLocal(store, args, plan.task);
        }
    }

    // One placeholder per continuation and resume entry first, so copies
    // can call and save any of them.
    var infos = collections.DenseMapUnmanaged(CFStmtId, SiteInfo).empty;
    defer infos.deinit(allocator);
    var hosted_procs = try std.DynamicBitSetUnmanaged.initEmpty(allocator, proc_count);
    defer hosted_procs.deinit(allocator);
    for (plans.items) |plan| {
        const source = store.getProcSpecImmediate(plan.proc).*;
        for (plan.sites.sites, 0..) |site, ordinal| {
            const call = store.getCFStmtImmediate(site.call).assign_call;
            const hosted = isHosted(store, call.proc);
            if (hosted) hosted_procs.set(@backingInt(call.proc));
            var info = SiteInfo{
                .live_after = site.live_after,
                .target = call.target,
                .hosted = hosted,
                .continuation = null,
                .resume_entry = null,
                .capture_layout = .zst,
                .on_drop = .none,
                .slot_drop = .none,
            };
            if (!site.tail) {
                var key: [4]u8 = undefined;
                std.mem.writeInt(u32, &key, @intCast(ordinal), .little);
                info.continuation = try store.addProcSpec(.{
                    .name = store.freshSyntheticSymbol(),
                    .identity = source.identity.derived("continuation", &key),
                    .args = .empty(),
                    .ret_layout = source.ret_layout,
                }, store.procLoc(plan.proc));
                try nameDerived(allocator, store, info.continuation.?, plan.proc, "continuation", ordinal);
                info.resume_entry = try store.addProcSpec(.{
                    .name = store.freshSyntheticSymbol(),
                    .identity = source.identity.derived("resume", &key),
                    .args = .empty(),
                    .ret_layout = source.ret_layout,
                    .abi = .erased_callable,
                }, store.procLoc(plan.proc));
                try nameDerived(allocator, store, info.resume_entry.?, plan.proc, "resume", ordinal);
                info.capture_layout = try captureLayout(allocator, store, layouts, site.live_after, call.target);
                info.on_drop = hostDrop(layouts, info.capture_layout);
                if (hosted) info.slot_drop = hostDrop(layouts, store.getLocal(call.target).layout_idx);
            }
            try infos.put(allocator, site.call, info);
        }
    }

    // The copies first, from bodies without edges.
    for (plans.items) |plan| {
        var scopes = try JoinScopes.build(allocator, store, store.getProcSpecImmediate(plan.proc).body.get().?);
        defer scopes.deinit();
        for (plan.sites.sites) |site| {
            const info = infos.get(site.call).?;
            const continuation = info.continuation orelse continue;
            try buildContinuation(allocator, store, layouts, &infos, &scopes, plan, site, continuation);
        }
    }

    for (plans.items) |plan| {
        var sink = FrameSink{ .store = store };
        defer sink.locals.deinit(store.allocator);
        for (plan.sites.sites) |site| {
            const info = infos.get(site.call).?;
            if (info.continuation == null) continue;
            try rewriteSite(store, layouts, &sink, info, plan.task, site.call);
        }
        for (sink.locals.items) |local| try appendLocal(store, &store.getProcSpecPtr(plan.proc).frame_locals, local);
        for (plan.sites.sites) |site| {
            const info = infos.get(site.call).?;
            if (info.continuation == null) continue;
            try buildResumeEntry(allocator, store, layouts, info, store.stmtOrigin(site.call));
        }
    }

    var hosted_iter = hosted_procs.iterator(.{});
    while (hosted_iter.next()) |index| try hostShape(store, layouts, @fromBackingInt(@intCast(index)));

    try SuspensionMarks.run(allocator, store);
    if (builtin.mode == .debug) try verify(allocator, store);
}

/// Give a procedure the pass derives from `source` its source location and
/// a debug name that says which of `source`'s sites it belongs to, so dumps
/// and name-keyed tests tell it from `source`.
fn nameDerived(allocator: Allocator, store: *LirStore, derived: ProcId, source: ProcId, role: []const u8, ordinal: usize) Allocator.Error!void {
    try store.copyProcDebugInfo(derived, source);
    const name = store.procDebugName(source) orelse return;
    const text = try std.fmt.allocPrint(allocator, "{s}#{s}{d}", .{ name, role, ordinal });
    defer allocator.free(text);
    try store.setProcDebugName(derived, text);
}

fn isHosted(store: *const LirStore, proc: ProcId) bool {
    return store.getProcSpecImmediate(proc).hosted.get() != null;
}

fn appendLocal(store: *LirStore, span: *LIR.LocalSpan, local: LocalId) Allocator.Error!void {
    try spliceLocals(store, span, &.{}, &.{local});
}

/// Replace `span` with `before`, then its locals, then `after`.
fn spliceLocals(store: *LirStore, span: *LIR.LocalSpan, before: []const LocalId, after: []const LocalId) Allocator.Error!void {
    const old_len = GuardedList.borrowLen(store.getLocalSpan(span.*));
    var locals = try std.ArrayList(LocalId).initCapacity(store.allocator, before.len + old_len + after.len);
    defer locals.deinit(store.allocator);
    locals.appendSliceAssumeCapacity(before);
    for (0..old_len) |i| locals.appendAssumeCapacity(GuardedList.at(store.getLocalSpan(span.*), i));
    locals.appendSliceAssumeCapacity(after);
    span.* = try store.addLocalSpan(locals.items);
}

/// The `host_drop` RC helper of `layout_idx`, or `none` when it does
/// nothing.
fn hostDrop(layouts: *const layout.Store, layout_idx: layout.Idx) LIR.ErasedCallableOnDrop {
    const key = layout.RcHelper{ .op = .host_drop, .layout_idx = layout_idx };
    if (layouts.rcHelperPlan(key) == .noop) return .none;
    return .{ .rc_helper = key };
}

/// The struct of the saved values' layouts, in the order they are live:
/// every value live after the site but its result.
fn captureLayout(allocator: Allocator, store: *const LirStore, layouts: *layout.Store, live_after: []const LocalId, target: LocalId) Allocator.Error!layout.Idx {
    var fields = std.ArrayList(layout.StructField).empty;
    defer fields.deinit(allocator);
    for (live_after) |live| {
        if (live == target) continue;
        try fields.append(allocator, .{ .index = @intCast(fields.items.len), .layout = store.getLocal(live).layout_idx });
    }
    return layouts.putStructFields(fields.items);
}

/// Where a site's new locals go: the cloner's when it is in a copy, the
/// procedure's frame when it is in the procedure itself.
const FrameSink = struct {
    store: *LirStore,
    locals: std.ArrayList(LocalId) = .empty,

    fn newLocal(self: *FrameSink, layout_idx: layout.Idx) Allocator.Error!LocalId {
        const local = try self.store.addLocal(.{ .layout_idx = layout_idx });
        try self.locals.append(self.store.allocator, local);
        return local;
    }
};

/// A copy's new locals are the cloner's.
fn CloneSink(comptime Cloner: type) type {
    return struct {
        cloner: Cloner,

        fn newLocal(self: @This(), layout_idx: layout.Idx) Allocator.Error!LocalId {
            return self.cloner.addTemp(layout_idx);
        }
    };
}

/// One occurrence of a site, in the locals of the procedure that holds it.
const Occurrence = struct {
    task: LocalId,
    target: LocalId,
    /// The site's live values, in the order of `SiteInfo.live_after`.
    live: []const LocalId,
    /// The call, without the task at a hosted site.
    proc: ProcId,
    args: LIR.LocalSpan,
    extra: LIR.StmtRowId(LIR.CallExtra),
};

/// `suspend_save task R(f, k) [saved]; suspend_return`, where the saved
/// values are the live ones other than the call's result.
fn pendingEdge(store: *LirStore, info: SiteInfo, occurrence: Occurrence, origin: LIR.StmtOrigin) Allocator.Error!CFStmtId {
    var saved = try std.ArrayList(LocalId).initCapacity(store.allocator, occurrence.live.len);
    defer saved.deinit(store.allocator);
    for (occurrence.live) |live| {
        if (live != occurrence.target) saved.appendAssumeCapacity(live);
    }
    const ret = try store.addCFStmt(.{ .suspend_return = {} }, origin);
    return store.addCFStmt(.{ .suspend_save = .{
        .task = occurrence.task,
        .data = try store.addStmtRow(LIR.SuspendSaveData, .{
            .proc = info.resume_entry.?,
            .saved = try store.addLocalSpan(saved.items),
            .capture_layout = info.capture_layout,
            .on_drop = info.on_drop,
            .slot_drop = info.slot_drop,
        }),
        .next = ret,
    } }, origin);
}

/// The statement that starts an occurrence of a site that is not a tail
/// site, with `ready` as the code that runs when nothing paused. A
/// procedure site keeps its call and tests the pending flag after it; a
/// hosted site reads the slot's address, calls the host, and branches on
/// the `RocPoll`.
fn siteHead(store: *LirStore, layouts: *layout.Store, sink: anytype, info: SiteInfo, occurrence: Occurrence, ready: CFStmtId, origin: LIR.StmtOrigin) Allocator.Error!LIR.CFStmt {
    const edge = try pendingEdge(store, info, occurrence, origin);
    if (!info.hosted) {
        const ready_flag = try sink.newLocal(.bool);
        const test_stmt = try store.addCFStmt(.{ .switch_initialized_payload = .{
            .cond = ready_flag,
            .payload = occurrence.target,
            .uninitialized_is_cold = true,
            .initialized_branch = ready,
            .uninitialized_branch = edge,
        } }, origin);
        const read = try store.addLowLevelStmt(ready_flag, .task_ready, &.{occurrence.task}, test_stmt, origin);
        return .{ .assign_call = .{
            .target = occurrence.target,
            .proc = occurrence.proc,
            .args = occurrence.args,
            .extra = occurrence.extra,
            .next = read,
        } };
    }

    const result_layout = store.getLocal(occurrence.target).layout_idx;
    const slot = try sink.newLocal(try layouts.insertPtr(result_layout));
    const poll = try sink.newLocal(.u32);
    const unit = try sink.newLocal(.zst);
    const pending = try store.addLowLevelStmt(unit, .task_set_pending, &.{occurrence.task}, edge, origin);
    const load = try store.addLowLevelStmt(occurrence.target, .ptr_load, &.{slot}, ready, origin);
    const branch = try store.addCFStmt(.{ .switch_stmt = .{
        .cond = poll,
        .branches = try store.addCFSwitchBranches(&.{.{ .value = roc_ready, .body = load }}),
        .default_branch = pending,
        .default_is_cold = true,
    } }, origin);
    var args = try std.ArrayList(LocalId).initCapacity(store.allocator, 2 + GuardedList.borrowLen(store.getLocalSpan(occurrence.args)));
    defer args.deinit(store.allocator);
    args.appendSliceAssumeCapacity(&.{ occurrence.task, slot });
    for (0..GuardedList.borrowLen(store.getLocalSpan(occurrence.args))) |i| args.appendAssumeCapacity(GuardedList.at(store.getLocalSpan(occurrence.args), i));
    const call = try store.addCFStmt(.{ .assign_call = .{
        .target = poll,
        .proc = occurrence.proc,
        .args = try store.addLocalSpan(args.items),
        .extra = occurrence.extra,
        .next = branch,
    } }, origin);
    return .{ .assign_low_level = .{
        .target = slot,
        .op = .task_hosted_slot,
        .rc_effect = try store.addRcEffect(LIR.LowLevel.task_hosted_slot.rcEffect()),
        .args = try store.addLocalSpan(&.{occurrence.task}),
        .next = call,
    } };
}

/// Give a site of the procedure itself its pending edge, in place.
fn rewriteSite(store: *LirStore, layouts: *layout.Store, sink: *FrameSink, info: SiteInfo, task: LocalId, site: CFStmtId) Allocator.Error!void {
    const call = store.getCFStmtImmediate(site).assign_call;
    const origin = store.stmtOrigin(site);
    const head = try siteHead(store, layouts, sink, info, .{
        .task = task,
        .target = call.target,
        .live = info.live_after,
        .proc = call.proc,
        .args = call.args,
        .extra = call.extra,
    }, call.next, origin);
    try store.replaceCFStmt(site, head, origin);
}

/// `R(f, k)`: load the saved values and the call's result, then call
/// `C(f, k)` with them and the task.
fn buildResumeEntry(allocator: Allocator, store: *LirStore, layouts: *layout.Store, info: SiteInfo, origin: LIR.StmtOrigin) Allocator.Error!void {
    const entry = info.resume_entry.?;
    const ret_layout = store.getProcSpecImmediate(entry).ret_layout;
    var frame = std.ArrayList(LocalId).empty;
    defer frame.deinit(allocator);
    const Fresh = struct {
        store: *LirStore,
        frame: *std.ArrayList(LocalId),
        allocator: Allocator,
        fn local(self: @This(), layout_idx: layout.Idx) Allocator.Error!LocalId {
            const id = try self.store.addLocal(.{ .layout_idx = layout_idx });
            try self.frame.append(self.allocator, id);
            return id;
        }
    };
    const fresh = Fresh{ .store = store, .frame = &frame, .allocator = allocator };

    const task = try fresh.local(.opaque_ptr);
    const capture = try fresh.local(.opaque_ptr);
    const reuse = try fresh.local(try layouts.insertErasedCallable());
    const result_layout = store.getLocal(info.target).layout_idx;
    const result = try fresh.local(result_layout);
    const address = try fresh.local(try layouts.insertPtr(result_layout));
    const value = try fresh.local(ret_layout);

    var fields = std.ArrayList(LocalId).empty;
    defer fields.deinit(allocator);
    var call_args = try std.ArrayList(LocalId).initCapacity(allocator, info.live_after.len + 1);
    defer call_args.deinit(allocator);
    for (info.live_after) |live| {
        if (live == info.target) {
            call_args.appendAssumeCapacity(result);
        } else {
            const field = try fresh.local(store.getLocal(live).layout_idx);
            try fields.append(allocator, field);
            call_args.appendAssumeCapacity(field);
        }
    }
    call_args.appendAssumeCapacity(task);

    const ret = try store.addCFStmt(.{ .ret = .{ .value = value } }, origin);
    const call = try store.addCFStmt(.{ .assign_call = .{
        .target = value,
        .proc = info.continuation.?,
        .args = try store.addLocalSpan(call_args.items),
        .next = ret,
    } }, origin);
    const load = try store.addLowLevelStmt(result, .ptr_load, &.{address}, call, origin);
    var head = try store.addLowLevelStmt(address, if (info.hosted) .task_hosted_slot else .task_result_buffer, &.{task}, load, origin);
    if (fields.items.len > 0) {
        if (info.capture_layout == .zst) {
            // Every saved value is zero-sized, so there is no capture to read.
            var index = fields.items.len;
            while (index > 0) {
                index -= 1;
                head = try store.addCFStmt(.{ .assign_struct = .{ .target = fields.items[index], .fields = .empty(), .next = head } }, origin);
            }
        } else {
            const record = try fresh.local(info.capture_layout);
            var index = fields.items.len;
            while (index > 0) {
                index -= 1;
                head = try store.addCFStmt(.{ .assign_ref = .{ .target = fields.items[index], .op = LIR.RefOp.field(record, @intCast(index)), .next = head } }, origin);
            }
            head = try store.addLowLevelStmt(record, .erased_capture_load, &.{ capture, reuse }, head, origin);
        }
    }

    std.mem.sort(LocalId, frame.items, {}, localLessThan);
    const spec = store.getProcSpecPtr(entry);
    spec.args = try store.addLocalSpan(&.{ task, capture, reuse });
    spec.frame_locals = try store.addLocalSpan(frame.items);
    spec.body = .some(head);
    spec.erased_capture_arg = .some(capture);
    spec.erased_reuse_arg = .some(reuse);
    spec.erased_call_args = .some(try store.internErasedCallArgsPlan(layouts, &.{.opaque_ptr}));
    spec.shapes = spec.shapes.merged(store.shapes);
}

/// Give a `suspending` hosted procedure the host's shape: the task and a
/// pointer to its result before its explicit arguments, and a `RocPoll`
/// result.
fn hostShape(store: *LirStore, layouts: *layout.Store, proc: ProcId) Allocator.Error!void {
    const result_layout = store.getProcSpecImmediate(proc).ret_layout;
    const task = try store.addLocal(.{ .layout_idx = .opaque_ptr });
    const out = try store.addLocal(.{ .layout_idx = try layouts.insertPtr(result_layout) });
    const spec = store.getProcSpecPtr(proc);
    try spliceLocals(store, &spec.args, &.{ task, out }, &.{});
    store.getProcSpecPtr(proc).ret_layout = .u32;
}

fn localLessThan(_: void, lhs: LocalId, rhs: LocalId) bool {
    return @backingInt(lhs) < @backingInt(rhs);
}

/// For every statement of a body, the joins in whose body or remainder it
/// lies, outermost first: the joins a jump from it may target.
const JoinScopes = struct {
    allocator: Allocator,
    /// The join statement of every join identity in the body.
    join_of: collections.DenseMapUnmanaged(LIR.JoinPointId, CFStmtId) = .empty,
    /// The enclosing join of each join statement, if any.
    parent_of: collections.DenseMapUnmanaged(LIR.JoinPointId, ?LIR.JoinPointId) = .empty,
    /// The innermost join enclosing each statement.
    innermost: collections.DenseMapUnmanaged(CFStmtId, ?LIR.JoinPointId) = .empty,

    fn build(allocator: Allocator, store: *const LirStore, body: CFStmtId) Allocator.Error!JoinScopes {
        var self = JoinScopes{ .allocator = allocator };
        errdefer self.deinit();
        const Item = struct { stmt: CFStmtId, scope: ?LIR.JoinPointId };
        var work = std.ArrayList(Item).empty;
        defer work.deinit(allocator);
        var successors = std.ArrayList(CFStmtId).empty;
        defer successors.deinit(allocator);
        try work.append(allocator, .{ .stmt = body, .scope = null });
        while (work.pop()) |item| {
            const slot = try self.innermost.getOrPut(allocator, item.stmt);
            if (slot.found_existing) continue;
            slot.value_ptr.* = item.scope;
            switch (store.getCFStmtImmediate(item.stmt).*) {
                .join => |join| {
                    try self.join_of.put(allocator, join.id, item.stmt);
                    try self.parent_of.put(allocator, join.id, item.scope);
                    try work.append(allocator, .{ .stmt = join.body, .scope = join.id });
                    try work.append(allocator, .{ .stmt = join.remainder, .scope = join.id });
                },
                .init_uninitialized,
                .assign_ref,
                .assign_literal,
                .assign_call,
                .assign_call_erased,
                .assign_packed_erased_fn,
                .assign_low_level,
                .assign_list,
                .assign_struct,
                .assign_tag,
                .store_struct,
                .store_tag,
                .set_local,
                .debug,
                .expect,
                .expect_err,
                .dyn,
                .runtime_error,
                .comptime_exhaustiveness_failed,
                .incref,
                .decref,
                .decref_if_initialized,
                .free,
                .switch_stmt,
                .switch_initialized_payload,
                .str_match,
                .str_match_set,
                .jump,
                .ret,
                .suspend_save,
                .suspend_return,
                .crash,
                => {
                    successors.clearRetainingCapacity();
                    try body_clone.appendSuccessors(store, &successors, item.stmt, allocator);
                    for (successors.items) |successor| try work.append(allocator, .{ .stmt = successor, .scope = item.scope });
                },
            }
        }
        return self;
    }

    fn deinit(self: *JoinScopes) void {
        self.join_of.deinit(self.allocator);
        self.parent_of.deinit(self.allocator);
        self.innermost.deinit(self.allocator);
    }

    /// How deeply `id` is nested: 0 for an outermost join.
    fn depth(self: *const JoinScopes, id: LIR.JoinPointId) usize {
        var count: usize = 0;
        var at = self.parent_of.get(id).?;
        while (at) |parent| : (at = self.parent_of.get(parent).?) count += 1;
        return count;
    }

    /// Whether `id` lexically encloses `stmt`.
    fn encloses(self: *const JoinScopes, id: LIR.JoinPointId, stmt: CFStmtId) bool {
        var at = self.innermost.get(stmt).?;
        while (at) |scope| : (at = self.parent_of.get(scope).?) {
            if (scope == id) return true;
        }
        return false;
    }
};

/// Clones the code after a site, stopping at each later site that is not a
/// tail site with a tail call to its continuation, and records the jump
/// targets it copies.
const ContinuationRewriter = struct {
    allocator: Allocator,
    layouts: *layout.Store,
    infos: *const collections.DenseMapUnmanaged(CFStmtId, SiteInfo),
    ret_layout: layout.Idx,
    /// The task of the procedure being copied.
    task: LocalId,
    jump_targets: std.ArrayList(LIR.JoinPointId) = .empty,

    pub fn interceptStmt(self: *ContinuationRewriter, cloner: anytype, old_id: CFStmtId, stmt: LIR.CFStmt, origin: LIR.StmtOrigin) Allocator.Error!body_clone.Intercept {
        switch (stmt) {
            .assign_call => |call| {
                const info = self.infos.get(old_id) orelse return .none;
                const continuation = info.continuation orelse return .none;
                const task = try cloner.mapLocal(self.task);
                var live = try std.ArrayList(LocalId).initCapacity(self.allocator, info.live_after.len);
                defer live.deinit(self.allocator);
                for (info.live_after) |local| live.appendAssumeCapacity(try cloner.mapLocal(local));

                // Ready: `r = C(f, j)(live..., task); ret r`.
                const result = try cloner.addTemp(self.ret_layout);
                const ret = try cloner.store.addCFStmt(.{ .ret = .{ .value = result } }, origin);
                var args = try std.ArrayList(LocalId).initCapacity(self.allocator, live.items.len + 1);
                defer args.deinit(self.allocator);
                args.appendSliceAssumeCapacity(live.items);
                args.appendAssumeCapacity(task);
                const tail = try cloner.store.addCFStmt(.{ .assign_call = .{
                    .target = result,
                    .proc = continuation,
                    .args = try cloner.store.addLocalSpan(args.items),
                    .next = ret,
                } }, origin);

                const head = try siteHead(cloner.store, self.layouts, CloneSink(@TypeOf(cloner)){ .cloner = cloner }, info, .{
                    .task = task,
                    .target = try cloner.mapLocal(call.target),
                    .live = live.items,
                    .proc = call.proc,
                    .args = try cloner.mapLocalSpan(call.args),
                    .extra = try cloner.mapCallExtra(call.extra),
                }, tail, origin);
                return .{ .done = try cloner.store.addCFStmt(head, origin) };
            },
            .jump => |jump| {
                try self.jump_targets.append(self.allocator, jump.target);
                return .none;
            },
            .init_uninitialized,
            .assign_ref,
            .assign_literal,
            .assign_call_erased,
            .assign_packed_erased_fn,
            .assign_low_level,
            .assign_list,
            .assign_struct,
            .assign_tag,
            .store_struct,
            .store_tag,
            .set_local,
            .debug,
            .expect,
            .expect_err,
            .dyn,
            .runtime_error,
            .comptime_exhaustiveness_failed,
            .incref,
            .decref,
            .decref_if_initialized,
            .free,
            .switch_stmt,
            .switch_initialized_payload,
            .str_match,
            .str_match_set,
            .join,
            .ret,
            .suspend_save,
            .suspend_return,
            .crash,
            => return .none,
        }
    }
};

fn buildContinuation(
    allocator: Allocator,
    store: *LirStore,
    layouts: *layout.Store,
    infos: *const collections.DenseMapUnmanaged(CFStmtId, SiteInfo),
    scopes: *const JoinScopes,
    plan: ProcPlan,
    site: ContinuationSites.Site,
    continuation: ProcId,
) Allocator.Error!void {
    const ret_layout = store.getProcSpecImmediate(plan.proc).ret_layout;
    var cloner = try body_clone.BodyCloner(ContinuationRewriter).initWithAllocator(store, .{
        .allocator = allocator,
        .layouts = layouts,
        .infos = infos,
        .ret_layout = ret_layout,
        .task = plan.task,
    }, allocator);
    defer cloner.deinit();
    defer cloner.rewriter.jump_targets.deinit(allocator);

    var args = try std.ArrayList(LocalId).initCapacity(allocator, site.live_after.len + 1);
    defer args.deinit(allocator);
    for (site.live_after) |live| args.appendAssumeCapacity(try cloner.mapLocal(live));
    args.appendAssumeCapacity(try cloner.mapLocal(plan.task));

    const call = store.getCFStmtImmediate(site.call).assign_call;
    var inner = try cloner.cloneStmt(call.next);

    // The enclosing joins the copy jumps to, and those their copied bodies
    // jump to in turn.
    var bodies = collections.DenseMapUnmanaged(LIR.JoinPointId, CFStmtId).empty;
    defer bodies.deinit(allocator);
    var wrapped = std.ArrayList(LIR.JoinPointId).empty;
    defer wrapped.deinit(allocator);
    var next_target: usize = 0;
    while (next_target < cloner.rewriter.jump_targets.items.len) : (next_target += 1) {
        const target = cloner.rewriter.jump_targets.items[next_target];
        if (bodies.contains(target) or !scopes.encloses(target, site.call)) continue;
        const join = store.getCFStmtImmediate(scopes.join_of.get(target).?).join;
        try bodies.put(allocator, target, try cloner.cloneStmt(join.body));
        try wrapped.append(allocator, target);
    }

    // Nest them as in the source, innermost around the copied code.
    const Wrapper = struct { id: LIR.JoinPointId, depth: usize };
    var wrappers = try std.ArrayList(Wrapper).initCapacity(allocator, wrapped.items.len);
    defer wrappers.deinit(allocator);
    for (wrapped.items) |id| wrappers.appendAssumeCapacity(.{ .id = id, .depth = scopes.depth(id) });
    std.mem.sort(Wrapper, wrappers.items, {}, struct {
        fn deeperFirst(_: void, lhs: Wrapper, rhs: Wrapper) bool {
            return lhs.depth > rhs.depth;
        }
    }.deeperFirst);
    for (wrappers.items) |wrapper| {
        const join_stmt = scopes.join_of.get(wrapper.id).?;
        const join = store.getCFStmtImmediate(join_stmt).join;
        inner = try store.addCFStmt(.{ .join = .{
            .id = join.id,
            .params = try cloner.mapLocalSpan(join.params),
            .extra = try cloner.mapJoinExtra(join.extra),
            .body = bodies.get(wrapper.id).?,
            .remainder = inner,
        } }, store.stmtOrigin(join_stmt));
    }

    var frame = try std.ArrayList(LocalId).initCapacity(allocator, cloner.new_locals.items.len);
    defer frame.deinit(allocator);
    frame.appendSliceAssumeCapacity(cloner.new_locals.items);
    std.mem.sort(LocalId, frame.items, {}, struct {
        fn lessThan(_: void, lhs: LocalId, rhs: LocalId) bool {
            return @backingInt(lhs) < @backingInt(rhs);
        }
    }.lessThan);

    const spec = store.getProcSpecPtr(continuation);
    spec.args = try store.addLocalSpan(args.items);
    spec.frame_locals = try store.addLocalSpan(frame.items);
    spec.body = .some(inner);
    spec.shapes = spec.shapes.merged(store.shapes);
}

/// The Debug check of the pass's output (design.md "Invariants"). It
/// analyzes the output's sites afresh and checks that every site that is
/// not a tail site has its pending test and edge, that each edge saves
/// exactly the values live after its site other than the result, that each
/// resume entry calls its continuation with its captures in order, and that
/// every call to a continuation is a tail site.
fn verify(allocator: Allocator, store: *const LirStore) Allocator.Error!void {
    var continuations = try std.DynamicBitSetUnmanaged.initEmpty(allocator, store.procSpecCount());
    defer continuations.deinit(allocator);
    const Call = struct { callee: ProcId, tail: bool };
    var calls = std.ArrayList(Call).empty;
    defer calls.deinit(allocator);

    for (0..store.procSpecCount()) |index| {
        const proc_id: ProcId = @fromBackingInt(@intCast(index));
        const proc = store.getProcSpecImmediate(proc_id);
        if (proc.body.get() == null or proc.suspends == .never) continue;
        var sites = try ContinuationSites.analyze(allocator, store, proc_id);
        defer sites.deinit();
        for (sites.sites) |site| {
            const call = store.getCFStmtImmediate(site.call).assign_call;
            try calls.append(allocator, .{ .callee = call.proc, .tail = site.tail });
            if (site.tail) continue;
            const save_id = pendingSave(store, call) orelse invariant("continuation pass left a site that is not a tail site without its pending test", .{});
            const save = store.getCFStmtImmediate(save_id).suspend_save;
            const data = store.stmtRow(save.data);
            continuations.set(@backingInt(try verifyResumeEntry(allocator, store, data)));

            // The saved values are the ones live after the site, apart from
            // the call's result, the task and a hosted site's slot address.
            var expected = std.ArrayList(LocalId).empty;
            defer expected.deinit(allocator);
            const call_args = store.getLocalSpan(call.args);
            const slot: ?LocalId = if (isHosted(store, call.proc)) GuardedList.at(call_args, 1) else null;
            for (site.live_after) |live| {
                if (live == call.target or live == save.task or (slot != null and live == slot.?)) continue;
                try expected.append(allocator, live);
            }
            var saved = std.ArrayList(LocalId).empty;
            defer saved.deinit(allocator);
            for (0..GuardedList.borrowLen(store.getLocalSpan(data.saved))) |i| try saved.append(allocator, GuardedList.at(store.getLocalSpan(data.saved), i));
            std.mem.sort(LocalId, saved.items, {}, localLessThan);
            if (!std.mem.eql(LocalId, expected.items, saved.items)) invariant("a pending edge does not save exactly the values live after its site", .{});
        }
    }
    for (calls.items) |call| {
        if (continuations.isSet(@backingInt(call.callee)) and !call.tail) invariant("a call to a continuation is not a tail site", .{});
    }
}

/// The `suspend_save` that a site's pending test leads to on its cold side,
/// or null when the site has no pending test.
fn pendingSave(store: *const LirStore, call: @FieldType(LIR.CFStmt, "assign_call")) ?CFStmtId {
    const next = store.getCFStmtImmediate(call.next).*;
    if (isHosted(store, call.proc)) {
        if (next != .switch_stmt) return null;
        const branch = next.switch_stmt;
        if (branch.cond != call.target or !branch.default_is_cold) return null;
        const pending = store.getCFStmtImmediate(branch.default_branch).*;
        if (pending != .assign_low_level or pending.assign_low_level.op != .task_set_pending) return null;
        if (store.getCFStmtImmediate(pending.assign_low_level.next).* != .suspend_save) return null;
        return pending.assign_low_level.next;
    }
    if (next != .assign_low_level or next.assign_low_level.op != .task_ready) return null;
    const test_stmt = store.getCFStmtImmediate(next.assign_low_level.next).*;
    if (test_stmt != .switch_initialized_payload) return null;
    const pending_test = test_stmt.switch_initialized_payload;
    if (pending_test.cond != next.assign_low_level.target or pending_test.payload != call.target or !pending_test.uninitialized_is_cold) return null;
    if (store.getCFStmtImmediate(pending_test.uninitialized_branch).* != .suspend_save) return null;
    return pending_test.uninitialized_branch;
}

/// Check that the resume entry `data` names reads its captures as fields in
/// order and passes them, with at most the call's result among them, then
/// its task, to a procedure taking exactly those arguments. Returns that
/// procedure, the site's continuation.
fn verifyResumeEntry(allocator: Allocator, store: *const LirStore, data: LIR.SuspendSaveData) Allocator.Error!ProcId {
    const entry = store.getProcSpecImmediate(data.proc);
    if (entry.abi != .erased_callable) invariant("a pending edge saves a procedure that is not an erased callable", .{});
    const entry_args = store.getLocalSpan(entry.args);
    if (GuardedList.borrowLen(entry_args) != 3) invariant("a resume entry does not take the task, its capture and its reuse input", .{});
    const task = GuardedList.at(entry_args, 0);

    var fields = std.ArrayList(LocalId).empty;
    defer fields.deinit(allocator);
    var result: ?LocalId = null;
    var at = entry.body.get() orelse invariant("a resume entry has no body", .{});
    const call = while (true) {
        switch (store.getCFStmtImmediate(at).*) {
            .assign_ref => |read| {
                if (read.op.kind != .field or read.op.index != fields.items.len) invariant("a resume entry reads its captures out of order", .{});
                try fields.append(allocator, read.target);
                at = read.next;
            },
            .assign_low_level => |op| {
                if (op.op == .ptr_load) result = op.target;
                at = op.next;
            },
            .assign_struct => |zero_sized| {
                try fields.append(allocator, zero_sized.target);
                at = zero_sized.next;
            },
            .assign_call => |found| break found,
            .init_uninitialized,
            .assign_literal,
            .assign_call_erased,
            .assign_packed_erased_fn,
            .assign_list,
            .assign_tag,
            .store_struct,
            .store_tag,
            .set_local,
            .debug,
            .expect,
            .expect_err,
            .dyn,
            .runtime_error,
            .comptime_exhaustiveness_failed,
            .incref,
            .decref,
            .decref_if_initialized,
            .free,
            .switch_stmt,
            .switch_initialized_payload,
            .str_match,
            .str_match_set,
            .join,
            .jump,
            .ret,
            .crash,
            .suspend_save,
            .suspend_return,
            => invariant("a resume entry's body is not the shape the continuation pass builds", .{}),
        }
    };
    if (fields.items.len != GuardedList.borrowLen(store.getLocalSpan(data.saved))) invariant("a resume entry reads a different number of captures than its record saves", .{});

    const call_args = store.getLocalSpan(call.args);
    const count = GuardedList.borrowLen(call_args);
    if (count == 0 or GuardedList.at(call_args, count - 1) != task) invariant("a resume entry does not pass its task last", .{});
    var next_field: usize = 0;
    for (0..count - 1) |i| {
        const arg = GuardedList.at(store.getLocalSpan(call.args), i);
        if (result != null and arg == result.?) continue;
        if (next_field >= fields.items.len or fields.items[next_field] != arg) invariant("a resume entry does not pass its captures in order", .{});
        next_field += 1;
    }
    if (next_field != fields.items.len) invariant("a resume entry does not pass every capture", .{});
    const continuation = store.getProcSpecImmediate(call.proc);
    if (GuardedList.borrowLen(store.getLocalSpan(continuation.args)) != count) invariant("a resume entry's call does not match its continuation's arguments", .{});
    return call.proc;
}

const testing = std.testing;

const Fixture = struct {
    store: LirStore,
    layouts: layout.Store,
    seed: ProcId,

    fn init() Allocator.Error!Fixture {
        var store = LirStore.init(testing.allocator);
        errdefer store.deinit();
        var layouts = try layout.Store.init(testing.allocator, .u64);
        errdefer layouts.deinit();
        const seed = try store.addProcSpec(.{
            .name = store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(1),
            .args = .empty(),
            .ret_layout = .u64,
            .external = true,
            .suspends = .may,
        }, .none);
        return .{ .store = store, .layouts = layouts, .seed = seed };
    }

    fn deinit(self: *Fixture) void {
        self.layouts.deinit();
        self.store.deinit();
    }

    fn local(self: *Fixture) Allocator.Error!LocalId {
        return self.store.addLocal(.{ .layout_idx = .u64 });
    }

    fn stmt(self: *Fixture, value: LIR.CFStmt) Allocator.Error!CFStmtId {
        return self.store.addCFStmt(value, .test_fixture);
    }

    fn callSeed(self: *Fixture, target: LocalId, next: CFStmtId) Allocator.Error!CFStmtId {
        return self.stmt(.{ .assign_call = .{ .target = target, .proc = self.seed, .args = .empty(), .next = next } });
    }

    fn addProc(self: *Fixture, args: []const LocalId, frame: []const LocalId, body: CFStmtId) Allocator.Error!ProcId {
        const id = try self.store.addProcSpec(.{
            .name = self.store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(@intCast(self.store.procSpecCount() + 1)),
            .args = try self.store.addLocalSpan(args),
            .frame_locals = try self.store.addLocalSpan(frame),
            .body = .some(body),
            .ret_layout = .u64,
        }, .none);
        try SuspensionMarks.run(testing.allocator, &self.store);
        return id;
    }

    fn spec(self: *Fixture, id: ProcId) LIR.LirProcSpec {
        return self.store.getProcSpecImmediate(id).*;
    }

    fn at(self: *Fixture, id: CFStmtId) LIR.CFStmt {
        return self.store.getCFStmtImmediate(id).*;
    }

    fn locals(self: *Fixture, span: LIR.LocalSpan) Allocator.Error![]LocalId {
        const list = self.store.getLocalSpan(span);
        const out = try testing.allocator.alloc(LocalId, GuardedList.borrowLen(list));
        for (out, 0..) |*item, i| item.* = GuardedList.at(self.store.getLocalSpan(span), i);
        return out;
    }
};

test "continuation pass declarations are referenced" {
    testing.refAllDecls(@This());
}

test "without a procedure that may suspend nothing changes" {
    var f = try Fixture.init();
    defer f.deinit();
    f.store.getProcSpecPtr(f.seed).suspends = .never;
    const t = try f.local();
    const ret = try f.stmt(.{ .ret = .{ .value = t } });
    const p = try f.addProc(&.{}, &.{t}, try f.callSeed(t, ret));
    const count = f.store.procSpecCount();
    try run(testing.allocator, &f.store, &f.layouts);
    try testing.expectEqual(count, f.store.procSpecCount());
    try testing.expectEqual(@as(usize, 0), f.store.getLocalSpan(f.spec(p).args).len);
}

test "a site's continuation takes its live values and the task and copies the code after it" {
    var f = try Fixture.init();
    defer f.deinit();
    const x = try f.local();
    const y = try f.local();
    const t = try f.local();
    const s = try f.local();
    const u = try f.local();
    // f(x, y) = t = seed(); s = {t, y}; u = seed(); ret u
    const ret = try f.stmt(.{ .ret = .{ .value = u } });
    const second = try f.callSeed(u, ret);
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ t, y }), .next = second } });
    const first = try f.callSeed(t, build);
    const p = try f.addProc(&.{ x, y }, &.{ x, y, t, s, u }, first);
    const count = f.store.procSpecCount();

    try run(testing.allocator, &f.store, &f.layouts);

    // f gains the task after its explicit arguments and passes it at both sites.
    const f_args = try f.locals(f.spec(p).args);
    defer testing.allocator.free(f_args);
    try testing.expectEqual(@as(usize, 3), f_args.len);
    const task = f_args[2];
    try testing.expectEqual(@import("layout").Idx.opaque_ptr, f.store.getLocal(task).layout_idx);
    for ([_]CFStmtId{ first, second }) |site| {
        const site_args = try f.locals(f.at(site).assign_call.args);
        defer testing.allocator.free(site_args);
        try testing.expectEqualSlices(LocalId, &.{task}, site_args);
    }

    // Only the first site has a continuation and resume entry; the second
    // is a tail site.
    try testing.expectEqual(count + 2, f.store.procSpecCount());
    const c: ProcId = @fromBackingInt(@intCast(count));
    try testing.expectEqual(LIR.Suspends.may, f.spec(c).suspends);
    const c_args = try f.locals(f.spec(c).args);
    defer testing.allocator.free(c_args);
    try testing.expectEqual(@as(usize, 3), c_args.len); // y, t, task
    try testing.expectEqual(@import("layout").Idx.opaque_ptr, f.store.getLocal(c_args[2]).layout_idx);
    for (c_args) |arg| {
        try testing.expect(arg != x and arg != y and arg != t and arg != task);
    }
    // C(y', t', task') = s' = {t', y'}; u' = seed(task'); ret u'
    const c_build = f.at(f.spec(c).body.get().?).assign_struct;
    const fields = try f.locals(c_build.fields);
    defer testing.allocator.free(fields);
    try testing.expectEqualSlices(LocalId, &.{ c_args[1], c_args[0] }, fields);
    const c_call = f.at(c_build.next).assign_call;
    try testing.expectEqual(f.seed, c_call.proc);
    const c_call_args = try f.locals(c_call.args);
    defer testing.allocator.free(c_call_args);
    try testing.expectEqualSlices(LocalId, &.{c_args[2]}, c_call_args);
    try testing.expectEqual(c_call.target, f.at(c_call.next).ret.value);
}

test "a site inside a loop gets a continuation that loops back to its own copy" {
    var f = try Fixture.init();
    defer f.deinit();
    const acc0 = try f.local();
    const acc = try f.local();
    const t = try f.local();
    const s = try f.local();
    const join_id: LIR.JoinPointId = @fromBackingInt(@intCast(1));
    // join L(acc) = { t = seed(); s = {acc, t}; acc = t; jump L } in { acc = acc0; jump L }
    const back = try f.stmt(.{ .jump = .{ .target = join_id } });
    const rebind = try f.stmt(.{ .set_local = .{ .target = acc, .value = t, .mode = .initialize_join_param, .next = back } });
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ acc, t }), .next = rebind } });
    const site = try f.callSeed(t, build);
    const enter = try f.stmt(.{ .jump = .{ .target = join_id } });
    const init_acc = try f.stmt(.{ .set_local = .{ .target = acc, .value = acc0, .mode = .initialize_join_param, .next = enter } });
    const join = try f.stmt(.{ .join = .{ .id = join_id, .params = try f.store.addLocalSpan(&.{acc}), .body = site, .remainder = init_acc } });
    _ = try f.addProc(&.{acc0}, &.{ acc0, acc, t, s }, join);
    const count = f.store.procSpecCount();

    try run(testing.allocator, &f.store, &f.layouts);

    try testing.expectEqual(count + 2, f.store.procSpecCount());
    const c: ProcId = @fromBackingInt(@intCast(count));
    const c_args = try f.locals(f.spec(c).args);
    defer testing.allocator.free(c_args);
    try testing.expectEqual(@as(usize, 3), c_args.len); // acc, t, task
    // C = join L(acc') { t' = seed(task'); <ready test> r = C(acc', t', task'); ret r }
    //     in { s' = {acc', t'}; acc' = t'; jump L }
    const c_join = f.at(f.spec(c).body.get().?).join;
    try testing.expectEqual(join_id, c_join.id);
    const params = try f.locals(c_join.params);
    defer testing.allocator.free(params);
    try testing.expectEqualSlices(LocalId, &.{c_args[0]}, params);
    const loop_call = f.at(c_join.body).assign_call;
    try testing.expectEqual(f.seed, loop_call.proc);
    try testing.expectEqual(c_args[1], loop_call.target);
    const ready = f.at(f.at(loop_call.next).assign_low_level.next).switch_initialized_payload;
    const again = f.at(ready.initialized_branch).assign_call;
    try testing.expectEqual(c, again.proc);
    const again_args = try f.locals(again.args);
    defer testing.allocator.free(again_args);
    try testing.expectEqualSlices(LocalId, c_args, again_args);
    try testing.expectEqual(again.target, f.at(again.next).ret.value);
    const c_build = f.at(c_join.remainder).assign_struct;
    const c_rebind = f.at(c_build.next).set_local;
    try testing.expectEqual(c_args[0], c_rebind.target);
    try testing.expectEqual(c_args[1], c_rebind.value);
    try testing.expectEqual(join_id, f.at(c_rebind.next).jump.target);
}

/// The statements a pending edge is made of: `suspend_save`, then
/// `suspend_return`. Returns the save's data.
fn expectPendingEdge(f: *Fixture, edge: CFStmtId, task: LocalId, resume_entry: ProcId, saved: []const LocalId) (Allocator.Error || error{ TestExpectedEqual, TestUnexpectedResult })!LIR.SuspendSaveData {
    const save = f.at(edge).suspend_save;
    try testing.expectEqual(task, save.task);
    const data = f.store.stmtRow(save.data);
    try testing.expectEqual(resume_entry, data.proc);
    const saved_locals = try f.locals(data.saved);
    defer testing.allocator.free(saved_locals);
    try testing.expectEqualSlices(LocalId, saved, saved_locals);
    try testing.expect(f.at(save.next) == .suspend_return);
    return data;
}

test "a procedure site tests the pending flag and saves its resume entry on the cold side" {
    var f = try Fixture.init();
    defer f.deinit();
    const y = try f.local();
    const t = try f.local();
    const s = try f.local();
    const u = try f.local();
    // f(y) = t = seed(); s = {t, y}; u = seed(); ret u
    const ret = try f.stmt(.{ .ret = .{ .value = u } });
    const second = try f.callSeed(u, ret);
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ t, y }), .next = second } });
    const first = try f.callSeed(t, build);
    const p = try f.addProc(&.{y}, &.{ y, t, s, u }, first);
    const count = f.store.procSpecCount();

    try run(testing.allocator, &f.store, &f.layouts);

    const r: ProcId = @fromBackingInt(@intCast(count + 1));
    const f_args = try f.locals(f.spec(p).args);
    defer testing.allocator.free(f_args);
    const task = f_args[1];

    // t = seed(task); ready = task_ready(task); switch_initialized_payload ready t
    const call = f.at(first).assign_call;
    try testing.expectEqual(t, call.target);
    const read = f.at(call.next).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.task_ready, read.op);
    const test_stmt = f.at(read.next).switch_initialized_payload;
    try testing.expectEqual(read.target, test_stmt.cond);
    try testing.expectEqual(t, test_stmt.payload);
    try testing.expect(test_stmt.uninitialized_is_cold);
    try testing.expectEqual(build, test_stmt.initialized_branch);
    // The cold side saves y, the one live value other than the result.
    const data = try expectPendingEdge(&f, test_stmt.uninitialized_branch, task, r, &.{y});
    try testing.expectEqual(f.store.getLocal(read.target).layout_idx, @import("layout").Idx.bool);
    try testing.expect(data.slot_drop == .none);
    // The frame holds the new flag.
    const frame = try f.locals(f.spec(p).frame_locals);
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.findScalar(LocalId, frame, read.target) != null);
    // The tail site has no test.
    try testing.expect(f.at(second).assign_call.next == ret);
}

test "a resume entry reads its capture and the result buffer and calls the continuation" {
    var f = try Fixture.init();
    defer f.deinit();
    const y = try f.local();
    const t = try f.local();
    const s = try f.local();
    // f(y) = t = seed(); s = {t, y}; ret s  (s is a u64 here; the shape is what matters)
    const ret = try f.stmt(.{ .ret = .{ .value = s } });
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ t, y }), .next = ret } });
    const first = try f.callSeed(t, build);
    _ = try f.addProc(&.{y}, &.{ y, t, s }, first);
    const count = f.store.procSpecCount();

    try run(testing.allocator, &f.store, &f.layouts);

    const c: ProcId = @fromBackingInt(@intCast(count));
    const r: ProcId = @fromBackingInt(@intCast(count + 1));
    const spec = f.spec(r);
    try testing.expectEqual(LIR.ProcAbi.erased_callable, spec.abi);
    // It may suspend exactly when its continuation may; this one has no
    // later site.
    try testing.expectEqual(LIR.Suspends.never, f.spec(c).suspends);
    try testing.expectEqual(f.spec(c).suspends, spec.suspends);
    const args = try f.locals(spec.args);
    defer testing.allocator.free(args);
    try testing.expectEqual(@as(usize, 3), args.len); // task, capture, reuse
    try testing.expectEqual(args[1], spec.erased_capture_arg.get().?);
    try testing.expectEqual(args[2], spec.erased_reuse_arg.get().?);
    try testing.expect(spec.erased_call_args.get() != null);

    // record = erased_capture_load(capture, reuse); y' = record.0;
    // a = task_result_buffer(task); t' = ptr_load(a); v = C(y', t', task); ret v
    const load = f.at(spec.body.get().?).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.erased_capture_load, load.op);
    const field = f.at(load.next).assign_ref;
    const address = f.at(field.next).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.task_result_buffer, address.op);
    const result = f.at(address.next).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.ptr_load, result.op);
    const call = f.at(result.next).assign_call;
    try testing.expectEqual(c, call.proc);
    const call_args = try f.locals(call.args);
    defer testing.allocator.free(call_args);
    try testing.expectEqualSlices(LocalId, &.{ field.target, result.target, args[0] }, call_args);
    try testing.expectEqual(call.target, f.at(call.next).ret.value);
}

test "a hosted site reads the slot's address, branches on the poll, and the hosted procedure takes the host's shape" {
    var f = try Fixture.init();
    defer f.deinit();
    const hosted_arg = try f.local();
    const hosted = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.forTest(99),
        .args = try f.store.addLocalSpan(&.{hosted_arg}),
        .ret_layout = .u64,
        .hosted = .some(.{ .symbol = try f.store.insertString("roc_test_suspending"), .dispatch_index = 0 }),
        .suspends = .may,
    }, .none);
    const x = try f.local();
    const t = try f.local();
    const s = try f.local();
    // f(x) = t = hosted(x); s = {t, x}; ret s
    const ret = try f.stmt(.{ .ret = .{ .value = s } });
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ t, x }), .next = ret } });
    const site = try f.stmt(.{ .assign_call = .{ .target = t, .proc = hosted, .args = try f.store.addLocalSpan(&.{x}), .next = build } });
    const p = try f.addProc(&.{x}, &.{ x, t, s }, site);
    const count = f.store.procSpecCount();

    try run(testing.allocator, &f.store, &f.layouts);

    const r: ProcId = @fromBackingInt(@intCast(count + 1));
    const f_args = try f.locals(f.spec(p).args);
    defer testing.allocator.free(f_args);
    const task = f_args[1];

    // The hosted procedure takes the task and a result pointer first and
    // returns a U32 poll.
    const hosted_args = try f.locals(f.spec(hosted).args);
    defer testing.allocator.free(hosted_args);
    try testing.expectEqual(@as(usize, 3), hosted_args.len);
    try testing.expectEqual(@import("layout").Idx.opaque_ptr, f.store.getLocal(hosted_args[0]).layout_idx);
    try testing.expectEqual(hosted_arg, hosted_args[2]);
    try testing.expectEqual(@import("layout").Idx.u32, f.spec(hosted).ret_layout);

    // slot = task_hosted_slot(task); poll = hosted(task, slot, x); switch poll
    const slot = f.at(site).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.task_hosted_slot, slot.op);
    const call = f.at(slot.next).assign_call;
    try testing.expectEqual(hosted, call.proc);
    const call_args = try f.locals(call.args);
    defer testing.allocator.free(call_args);
    try testing.expectEqualSlices(LocalId, &.{ task, slot.target, x }, call_args);
    try testing.expectEqual(@import("layout").Idx.u32, f.store.getLocal(call.target).layout_idx);
    const branch = f.at(call.next).switch_stmt;
    try testing.expectEqual(call.target, branch.cond);
    try testing.expect(branch.default_is_cold);
    // Ready: t = ptr_load(slot), then the code after the call.
    const ready = f.store.getCFSwitchBranches(branch.branches);
    try testing.expectEqual(@as(usize, 1), GuardedList.borrowLen(ready));
    const ready_branch = GuardedList.at(f.store.getCFSwitchBranches(branch.branches), 0);
    try testing.expectEqual(@as(u64, 0), ready_branch.value);
    const load = f.at(ready_branch.body).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.ptr_load, load.op);
    try testing.expectEqual(t, load.target);
    try testing.expectEqual(build, load.next);
    // Pending: set the flag, save x, return.
    const pending = f.at(branch.default_branch).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.task_set_pending, pending.op);
    _ = try expectPendingEdge(&f, pending.next, task, r, &.{x});

    // The resume entry reads the result from the hosted slot.
    const entry = f.spec(r);
    const capture_load = f.at(entry.body.get().?).assign_low_level;
    const field = f.at(capture_load.next).assign_ref;
    try testing.expectEqual(LIR.LowLevel.task_hosted_slot, f.at(field.next).assign_low_level.op);
}

/// Run the pass on a procedure with one site, then drop the record's one
/// saved value, as a pass that lost track of a live value would.
fn verifyRecordMissingAValue() Allocator.Error!void {
    var f = try Fixture.init();
    defer f.deinit();
    const y = try f.local();
    const t = try f.local();
    const s = try f.local();
    const ret = try f.stmt(.{ .ret = .{ .value = s } });
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ t, y }), .next = ret } });
    const first = try f.callSeed(t, build);
    _ = try f.addProc(&.{y}, &.{ y, t, s }, first);
    try run(testing.allocator, &f.store, &f.layouts);

    const read = f.at(f.at(first).assign_call.next).assign_low_level;
    const edge = f.at(read.next).switch_initialized_payload.uninitialized_branch;
    var data = f.store.stmtRow(f.at(edge).suspend_save.data);
    data.saved = .empty();
    const dropped = try f.store.addStmtRow(LIR.SuspendSaveData, data);
    f.store.getCFStmtPtr(edge).suspend_save.data = dropped;
    try verify(testing.allocator, &f.store);
}

test "the verifier rejects a record that does not save every live value" {
    try @import("base").death_test.expectPanic("a resume entry reads a different number of captures", verifyRecordMissingAValue, .{});
}

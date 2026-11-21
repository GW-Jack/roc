//! The continuation pass (design.md "The Continuation Pass").
//!
//! For every procedure that may suspend, this gives the procedure the task
//! as a hidden argument, passes it at every suspension site, and makes a
//! continuation procedure `C(f, k)` for every site `k` that is not a tail
//! site. A continuation is a copy of the code after its call, inside copies
//! of the enclosing joins that code can jump to, stopped at every later
//! site by a tail call to that site's continuation.
//!
//! Pending edges and resume entries, which make the continuations
//! reachable, are added on top of this.

const std = @import("std");
const collections = @import("collections");
const core = @import("lir_core");
const body_clone = @import("body_clone.zig");
const ContinuationSites = @import("continuation_sites.zig");
const SuspensionMarks = @import("suspension_marks.zig");

const LIR = core.LIR;
const LirStore = core.LirStore;
const GuardedList = LirStore.GuardedList;
const Allocator = std.mem.Allocator;
const CFStmtId = LIR.CFStmtId;
const LocalId = LIR.LocalId;
const ProcId = LIR.LirProcSpecId;

/// What the pass knows about one site of the procedure that contains it.
const SiteInfo = struct {
    live_after: []const LocalId,
    /// The site's continuation, or null for a tail site.
    continuation: ?ProcId,
};

const ProcPlan = struct {
    proc: ProcId,
    sites: ContinuationSites.Sites,
    task: LocalId,
};

/// Give every procedure that may suspend its task argument and make the
/// continuation of each of its sites that is not a tail site.
pub fn run(allocator: Allocator, store: *LirStore) Allocator.Error!void {
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

    // One placeholder per continuation first, so copies can call any of them.
    var infos = collections.DenseMapUnmanaged(CFStmtId, SiteInfo).empty;
    defer infos.deinit(allocator);
    for (plans.items) |plan| {
        const source = store.getProcSpecImmediate(plan.proc).*;
        for (plan.sites.sites, 0..) |site, ordinal| {
            var continuation: ?ProcId = null;
            if (!site.tail) {
                var key: [4]u8 = undefined;
                std.mem.writeInt(u32, &key, @intCast(ordinal), .little);
                continuation = try store.addProcSpec(.{
                    .name = store.freshSyntheticSymbol(),
                    .identity = source.identity.derived("continuation", &key),
                    .args = .empty(),
                    .ret_layout = source.ret_layout,
                }, store.procLoc(plan.proc));
                try store.copyProcDebugInfo(continuation.?, plan.proc);
            }
            try infos.put(allocator, site.call, .{ .live_after = site.live_after, .continuation = continuation });
        }
    }

    for (plans.items) |plan| {
        var scopes = try JoinScopes.build(allocator, store, store.getProcSpecImmediate(plan.proc).body.get().?);
        defer scopes.deinit();
        for (plan.sites.sites) |site| {
            const info = infos.get(site.call).?;
            const continuation = info.continuation orelse continue;
            try buildContinuation(allocator, store, &infos, &scopes, plan, site, continuation);
        }
    }

    try SuspensionMarks.run(allocator, store);
}

fn isHosted(store: *const LirStore, proc: ProcId) bool {
    return store.getProcSpecImmediate(proc).hosted.get() != null;
}

fn appendLocal(store: *LirStore, span: *LIR.LocalSpan, local: LocalId) Allocator.Error!void {
    const old = store.getLocalSpan(span.*);
    var locals = try std.ArrayList(LocalId).initCapacity(store.allocator, GuardedList.borrowLen(old) + 1);
    defer locals.deinit(store.allocator);
    for (0..GuardedList.borrowLen(old)) |i| locals.appendAssumeCapacity(GuardedList.at(store.getLocalSpan(span.*), i));
    locals.appendAssumeCapacity(local);
    span.* = try store.addLocalSpan(locals.items);
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
    infos: *const collections.DenseMapUnmanaged(CFStmtId, SiteInfo),
    ret_layout: @import("layout").Idx,
    jump_targets: std.ArrayList(LIR.JoinPointId) = .empty,

    pub fn interceptStmt(self: *ContinuationRewriter, cloner: anytype, old_id: CFStmtId, stmt: LIR.CFStmt, origin: LIR.StmtOrigin) Allocator.Error!body_clone.Intercept {
        switch (stmt) {
            .assign_call => |call| {
                const info = self.infos.get(old_id) orelse return .none;
                const continuation = info.continuation orelse return .none;
                const result = try cloner.addTemp(self.ret_layout);
                const ret = try cloner.store.addCFStmt(.{ .ret = .{ .value = result } }, origin);
                var args = try std.ArrayList(LocalId).initCapacity(self.allocator, info.live_after.len + 1);
                defer args.deinit(self.allocator);
                for (info.live_after) |live| args.appendAssumeCapacity(try cloner.mapLocal(live));
                // The call passes the task last; the continuation takes it
                // last too.
                const call_args = cloner.store.getLocalSpan(call.args);
                args.appendAssumeCapacity(try cloner.mapLocal(GuardedList.at(call_args, GuardedList.borrowLen(call_args) - 1)));
                const tail = try cloner.store.addCFStmt(.{ .assign_call = .{
                    .target = result,
                    .proc = continuation,
                    .args = try cloner.store.addLocalSpan(args.items),
                    .next = ret,
                } }, origin);
                return .{ .done = try cloner.store.addCFStmt(.{ .assign_call = .{
                    .target = try cloner.mapLocal(call.target),
                    .proc = call.proc,
                    .args = try cloner.mapLocalSpan(call.args),
                    .extra = try cloner.mapCallExtra(call.extra),
                    .next = tail,
                } }, origin) };
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
    infos: *const collections.DenseMapUnmanaged(CFStmtId, SiteInfo),
    scopes: *const JoinScopes,
    plan: ProcPlan,
    site: ContinuationSites.Site,
    continuation: ProcId,
) Allocator.Error!void {
    const ret_layout = store.getProcSpecImmediate(plan.proc).ret_layout;
    var cloner = try body_clone.BodyCloner(ContinuationRewriter).initWithAllocator(store, .{
        .allocator = allocator,
        .infos = infos,
        .ret_layout = ret_layout,
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

const testing = std.testing;

const Fixture = struct {
    store: LirStore,
    seed: ProcId,

    fn init() Allocator.Error!Fixture {
        var store = LirStore.init(testing.allocator);
        errdefer store.deinit();
        const seed = try store.addProcSpec(.{
            .name = store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(1),
            .args = .empty(),
            .ret_layout = .u64,
            .external = true,
            .suspends = .may,
        }, .none);
        return .{ .store = store, .seed = seed };
    }

    fn deinit(self: *Fixture) void {
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
    try run(testing.allocator, &f.store);
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

    try run(testing.allocator, &f.store);

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

    // Only the first site has a continuation; the second is a tail site.
    try testing.expectEqual(count + 1, f.store.procSpecCount());
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

    try run(testing.allocator, &f.store);

    try testing.expectEqual(count + 1, f.store.procSpecCount());
    const c: ProcId = @fromBackingInt(@intCast(count));
    const c_args = try f.locals(f.spec(c).args);
    defer testing.allocator.free(c_args);
    try testing.expectEqual(@as(usize, 3), c_args.len); // acc, t, task
    // C = join L(acc') { t' = seed(task'); r = C(acc', t', task'); ret r } in { s' = {acc', t'}; acc' = t'; jump L }
    const c_join = f.at(f.spec(c).body.get().?).join;
    try testing.expectEqual(join_id, c_join.id);
    const params = try f.locals(c_join.params);
    defer testing.allocator.free(params);
    try testing.expectEqualSlices(LocalId, &.{c_args[0]}, params);
    const loop_call = f.at(c_join.body).assign_call;
    try testing.expectEqual(f.seed, loop_call.proc);
    try testing.expectEqual(c_args[1], loop_call.target);
    const again = f.at(loop_call.next).assign_call;
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

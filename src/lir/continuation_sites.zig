//! The suspension sites of one procedure, as the continuation pass needs
//! them (design.md "The Continuation Pass"): each site's live values after
//! the call, and whether it is a tail site.
//!
//! A value is live after a call when some path from the call's successor
//! reads it before writing it. A join's `retained` locals count as read at
//! the start of its body; jumps carry no operands, since `set_local`s before
//! them write the join's parameters. Reads and definitions come from the
//! shared inventories in `body_clone`, and the fixpoint is `arc_liveness`.
//!
//! A tail site is a call to a procedure (never a hosted one) whose result
//! the procedure returns unchanged: the next statements only copy it into
//! join parameters with `set_local` and jump, until a `ret` returns a local
//! that still holds it.

const std = @import("std");
const collections = @import("collections");
const core = @import("lir_core");
const body_clone = @import("body_clone.zig");
const arc_liveness = @import("arc_liveness.zig");
const invariant = @import("base").invariant;

const LIR = core.LIR;
const LirStore = core.LirStore;
const Allocator = std.mem.Allocator;
const CFStmtId = LIR.CFStmtId;
const LocalId = LIR.LocalId;

/// One suspension site and what the continuation pass needs about it.
pub const Site = struct {
    /// The `assign_call` statement whose `CallExtra` marks it a site.
    call: CFStmtId,
    tail: bool,
    /// The values live after the call, the call's target included when the
    /// code after it reads it, in ascending local order.
    live_after: []const LocalId,
};

/// One procedure's sites, in the order a depth-first walk of its body
/// reaches them. `deinit` frees everything.
pub const Sites = struct {
    arena: std.heap.ArenaAllocator,
    sites: []const Site,

    pub fn deinit(self: *Sites) void {
        self.arena.deinit();
    }
};

/// Analyze `proc_id`, which has a body. A procedure without sites gets an
/// empty list.
pub fn analyze(allocator: Allocator, store: *const LirStore, proc_id: LIR.LirProcSpecId) Allocator.Error!Sites {
    var result = Sites{ .arena = std.heap.ArenaAllocator.init(allocator), .sites = &.{} };
    errdefer result.arena.deinit();
    const out = result.arena.allocator();

    var builder = Builder{ .store = store, .allocator = allocator };
    defer builder.deinit();
    const body = store.getProcSpecImmediate(proc_id).body.get() orelse invariant("continuation sites of a procedure without a body", .{});
    try builder.walk(body);

    var site_nodes = std.ArrayList(u32).empty;
    defer site_nodes.deinit(allocator);
    for (builder.stmts.items, 0..) |stmt_id, node| {
        const stmt = store.getCFStmtImmediate(stmt_id);
        if (stmt.* != .assign_call) continue;
        if (!store.stmtRowOrDefault(stmt.assign_call.extra).suspension_site) continue;
        try site_nodes.append(allocator, @intCast(node));
    }
    if (site_nodes.items.len == 0) return result;

    var graph_storage = try builder.graph();
    defer graph_storage.deinit(allocator);
    var rows_arena = std.heap.ArenaAllocator.init(allocator);
    defer rows_arena.deinit();
    const rows = try arc_liveness.solve(rows_arena.allocator(), allocator, &graph_storage.graph);

    const sites = try out.alloc(Site, site_nodes.items.len);
    for (site_nodes.items, sites) |node, *site| {
        const call_id = builder.stmts.items[node];
        const call = store.getCFStmtImmediate(call_id).assign_call;
        const next_node = builder.node_of.get(call.next) orelse invariant("a suspension site's successor was not walked", .{});
        const row = &rows[next_node];
        const live = try out.alloc(LocalId, row.count());
        var it = row.iterator();
        var i: usize = 0;
        while (it.next()) |bit| : (i += 1) live[i] = builder.locals.items[bit];
        std.mem.sort(LocalId, live, {}, localLessThan);
        site.* = .{
            .call = call_id,
            .tail = try isTailSite(allocator, store, &builder.join_of, call),
            .live_after = live,
        };
    }
    result.sites = sites;
    return result;
}

fn localLessThan(_: void, lhs: LocalId, rhs: LocalId) bool {
    return @backingInt(lhs) < @backingInt(rhs);
}

fn isTailSite(
    allocator: Allocator,
    store: *const LirStore,
    join_of: *const collections.DenseMapUnmanaged(LIR.JoinPointId, CFStmtId),
    call: @FieldType(LIR.CFStmt, "assign_call"),
) Allocator.Error!bool {
    if (store.getProcSpecImmediate(call.proc).hosted.get() != null) return false;
    // The locals that hold the call's result on the path being followed.
    var holders = collections.DenseMapUnmanaged(LocalId, void).empty;
    defer holders.deinit(allocator);
    try holders.put(allocator, call.target, {});
    var entered = collections.DenseMapUnmanaged(LIR.JoinPointId, void).empty;
    defer entered.deinit(allocator);
    var at = call.next;
    while (true) {
        switch (store.getCFStmtImmediate(at).*) {
            .ret => |ret| return holders.contains(ret.value),
            .set_local => |set| {
                if (holders.contains(set.value)) {
                    try holders.put(allocator, set.target, {});
                } else {
                    _ = holders.remove(set.target);
                }
                at = set.next;
            },
            .jump => |jump| {
                // A path that enters the same join twice loops; it never
                // returns the result unchanged.
                if ((try entered.getOrPut(allocator, jump.target)).found_existing) return false;
                const join_stmt = join_of.get(jump.target) orelse invariant("a jump's join was not walked", .{});
                at = store.getCFStmtImmediate(join_stmt).join.body;
            },
            // Anything else does work after the call.
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
            .suspend_save,
            .suspend_return,
            .crash,
            .join,
            => return false,
        }
    }
}

/// Builds the read-before-write graph of one body: a node per reachable
/// statement and a bit per local it mentions.
const Builder = struct {
    store: *const LirStore,
    allocator: Allocator,
    stmts: std.ArrayList(CFStmtId) = .empty,
    node_of: collections.DenseMapUnmanaged(CFStmtId, u32) = .empty,
    locals: std.ArrayList(LocalId) = .empty,
    bit_of: collections.DenseMapUnmanaged(LocalId, u32) = .empty,
    join_of: collections.DenseMapUnmanaged(LIR.JoinPointId, CFStmtId) = .empty,
    succs: std.ArrayList(std.ArrayList(u32)) = .empty,
    reads: std.ArrayList(std.ArrayList(u32)) = .empty,
    defs: std.ArrayList(std.ArrayList(u32)) = .empty,
    work: std.ArrayList(u32) = .empty,
    failed: ?Allocator.Error = null,

    fn deinit(self: *Builder) void {
        for (self.succs.items) |*list| list.deinit(self.allocator);
        for (self.reads.items) |*list| list.deinit(self.allocator);
        for (self.defs.items) |*list| list.deinit(self.allocator);
        self.succs.deinit(self.allocator);
        self.reads.deinit(self.allocator);
        self.defs.deinit(self.allocator);
        self.stmts.deinit(self.allocator);
        self.node_of.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        self.bit_of.deinit(self.allocator);
        self.join_of.deinit(self.allocator);
        self.work.deinit(self.allocator);
    }

    fn nodeFor(self: *Builder, stmt: CFStmtId) Allocator.Error!u32 {
        const slot = try self.node_of.getOrPut(self.allocator, stmt);
        if (slot.found_existing) return slot.value_ptr.*;
        const node: u32 = @intCast(self.stmts.items.len);
        slot.value_ptr.* = node;
        try self.stmts.append(self.allocator, stmt);
        try self.succs.append(self.allocator, .empty);
        try self.reads.append(self.allocator, .empty);
        try self.defs.append(self.allocator, .empty);
        try self.work.append(self.allocator, node);
        return node;
    }

    fn bitFor(self: *Builder, local: LocalId) Allocator.Error!u32 {
        const slot = try self.bit_of.getOrPut(self.allocator, local);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(self.locals.items.len);
            try self.locals.append(self.allocator, local);
        }
        return slot.value_ptr.*;
    }

    const Note = struct { builder: *Builder, list: *std.ArrayList(u32) };

    fn note(ctx: Note, local: LocalId) void {
        if (ctx.builder.failed != null) return;
        const bit = ctx.builder.bitFor(local) catch |err| {
            ctx.builder.failed = err;
            return;
        };
        ctx.list.append(ctx.builder.allocator, bit) catch |err| {
            ctx.builder.failed = err;
        };
    }

    fn noteSpan(self: *Builder, list: *std.ArrayList(u32), span: LIR.LocalSpan) Allocator.Error!void {
        const locals = self.store.getLocalSpan(span);
        for (0..LirStore.GuardedList.borrowLen(locals)) |i| {
            try list.append(self.allocator, try self.bitFor(LirStore.GuardedList.at(locals, i)));
        }
    }

    fn walk(self: *Builder, body: CFStmtId) Allocator.Error!void {
        _ = try self.nodeFor(body);
        var successors = std.ArrayList(CFStmtId).empty;
        defer successors.deinit(self.allocator);
        while (self.work.pop()) |node| {
            const stmt_id = self.stmts.items[node];
            const stmt = self.store.getCFStmtImmediate(stmt_id).*;
            successors.clearRetainingCapacity();
            switch (stmt) {
                .join => |join| {
                    // Entering a join continues with its remainder; its body
                    // runs only through jumps, so its node is made by the
                    // first jump that reaches it.
                    try self.join_of.put(self.allocator, join.id, stmt_id);
                    try successors.append(self.allocator, join.remainder);
                },
                .jump => |jump| {
                    const join_stmt = self.join_of.get(jump.target) orelse invariant("a jump was reached before its join", .{});
                    const join = self.store.getCFStmtImmediate(join_stmt).join;
                    const first = !self.node_of.contains(join.body);
                    const body_node = try self.nodeFor(join.body);
                    if (first) try self.noteSpan(&self.reads.items[body_node], self.store.stmtRowOrDefault(join.extra).retained);
                    try successors.append(self.allocator, join.body);
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
                .ret,
                .suspend_save,
                .suspend_return,
                .crash,
                => {
                    try body_clone.appendSuccessors(self.store, &successors, stmt_id, self.allocator);
                    body_clone.forEachStmtRead(self.store, stmt, Note{ .builder = self, .list = &self.reads.items[node] }, note);
                    body_clone.forEachStmtDef(self.store, stmt, Note{ .builder = self, .list = &self.defs.items[node] }, note);
                    if (self.failed) |err| return err;
                },
            }
            for (successors.items) |successor| {
                const succ_node = try self.nodeFor(successor);
                try self.succs.items[node].append(self.allocator, succ_node);
            }
        }
    }

    const GraphStorage = struct {
        graph: arc_liveness.Graph,
        buffers: [8][]u32,

        fn deinit(self: *GraphStorage, allocator: Allocator) void {
            for (self.buffers) |buffer| allocator.free(buffer);
        }
    };

    fn flatten(allocator: Allocator, lists: []const std.ArrayList(u32)) Allocator.Error!struct { starts: []u32, items: []u32 } {
        const starts = try allocator.alloc(u32, lists.len + 1);
        errdefer allocator.free(starts);
        var total: u32 = 0;
        for (lists, 0..) |list, i| {
            starts[i] = total;
            total += @intCast(list.items.len);
        }
        starts[lists.len] = total;
        const items = try allocator.alloc(u32, total);
        for (lists, 0..) |list, i| @memcpy(items[starts[i]..starts[i + 1]], list.items);
        return .{ .starts = starts, .items = items };
    }

    fn graph(self: *Builder) Allocator.Error!GraphStorage {
        const node_count = self.stmts.items.len;
        var preds = try self.allocator.alloc(std.ArrayList(u32), node_count);
        defer {
            for (preds) |*list| list.deinit(self.allocator);
            self.allocator.free(preds);
        }
        for (preds) |*list| list.* = .empty;
        for (self.succs.items, 0..) |list, node| {
            for (list.items) |succ| try preds[succ].append(self.allocator, @intCast(node));
        }
        const succs = try flatten(self.allocator, self.succs.items);
        const pred_flat = try flatten(self.allocator, preds);
        const read_flat = try flatten(self.allocator, self.reads.items);
        const def_flat = try flatten(self.allocator, self.defs.items);
        return .{
            .graph = .{
                .succ_starts = succs.starts,
                .succs = succs.items,
                .pred_starts = pred_flat.starts,
                .preds = pred_flat.items,
                .read_starts = read_flat.starts,
                .reads = read_flat.items,
                .def_starts = def_flat.starts,
                .defs = def_flat.items,
                .bit_len = self.locals.items.len,
            },
            .buffers = .{ succs.starts, succs.items, pred_flat.starts, pred_flat.items, read_flat.starts, read_flat.items, def_flat.starts, def_flat.items },
        };
    }
};

const testing = std.testing;
const SuspensionMarks = @import("suspension_marks.zig");

const Fixture = struct {
    store: LirStore,
    seed: LIR.LirProcSpecId,
    hosted: LIR.LirProcSpecId,

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
        const hosted = try store.addProcSpec(.{
            .name = store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(2),
            .args = .empty(),
            .ret_layout = .u64,
            .suspends = .may,
            .hosted = .some(.{ .symbol = try store.insertString("roc_test_suspending"), .dispatch_index = 0 }),
        }, .none);
        return .{ .store = store, .seed = seed, .hosted = hosted };
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

    fn call(self: *Fixture, target: LocalId, proc: LIR.LirProcSpecId, next: CFStmtId) Allocator.Error!CFStmtId {
        return self.stmt(.{ .assign_call = .{ .target = target, .proc = proc, .args = .empty(), .next = next } });
    }

    fn set(self: *Fixture, target: LocalId, value: LocalId, next: CFStmtId) Allocator.Error!CFStmtId {
        return self.stmt(.{ .set_local = .{ .target = target, .value = value, .mode = .initialize_join_param, .next = next } });
    }

    /// Add a procedure with `args` and `body`, then commit the marks.
    fn addProc(self: *Fixture, args: []const LocalId, body: CFStmtId) Allocator.Error!LIR.LirProcSpecId {
        const id = try self.store.addProcSpec(.{
            .name = self.store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(@intCast(self.store.procSpecCount() + 1)),
            .args = try self.store.addLocalSpan(args),
            .body = .some(body),
            .ret_layout = .u64,
        }, .none);
        try SuspensionMarks.run(testing.allocator, &self.store);
        return id;
    }
};

fn expectLive(expected: []const LocalId, site: Site) error{TestExpectedEqual}!void {
    try testing.expectEqualSlices(LocalId, expected, site.live_after);
}

test "continuation sites declarations are referenced" {
    testing.refAllDecls(@This());
}

test "live values after a site are the ones read later, and a returned result is a tail site" {
    var f = try Fixture.init();
    defer f.deinit();
    const x = try f.local();
    const y = try f.local();
    const t = try f.local();
    const s = try f.local();
    const u = try f.local();
    // t = seed(); s = {t, y}; u = seed(); ret u   (x is never read)
    const ret = try f.stmt(.{ .ret = .{ .value = u } });
    const second = try f.call(u, f.seed, ret);
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ t, y }), .next = second } });
    const first = try f.call(t, f.seed, build);
    const p = try f.addProc(&.{ x, y }, first);

    var sites = try analyze(testing.allocator, &f.store, p);
    defer sites.deinit();
    try testing.expectEqual(@as(usize, 2), sites.sites.len);
    const by_call = if (sites.sites[0].call == first) sites.sites else &[_]Site{ sites.sites[1], sites.sites[0] };
    try testing.expect(!by_call[0].tail);
    try expectLive(&.{ y, t }, by_call[0]);
    try testing.expect(by_call[1].tail);
    try expectLive(&.{u}, by_call[1]);
}

test "a result passed to a join that returns it is a tail site; one overwritten first is not" {
    for ([_]bool{ false, true }) |overwrite| {
        var f = try Fixture.init();
        defer f.deinit();
        const y = try f.local();
        const t = try f.local();
        const param = try f.local();
        const join_id: LIR.JoinPointId = @fromBackingInt(@intCast(1));
        // join J(param) = ret param in { t = seed(); param = t; [param = y;] jump J }
        const body = try f.stmt(.{ .ret = .{ .value = param } });
        const jump = try f.stmt(.{ .jump = .{ .target = join_id } });
        const after = if (overwrite) try f.set(param, y, jump) else jump;
        const pass = try f.set(param, t, after);
        const call = try f.call(t, f.seed, pass);
        const join = try f.stmt(.{ .join = .{ .id = join_id, .params = try f.store.addLocalSpan(&.{param}), .body = body, .remainder = call } });
        const p = try f.addProc(&.{y}, join);

        var sites = try analyze(testing.allocator, &f.store, p);
        defer sites.deinit();
        try testing.expectEqual(@as(usize, 1), sites.sites.len);
        try testing.expectEqual(!overwrite, sites.sites[0].tail);
        // `param = t` reads t even when a later write replaces param.
        if (overwrite) try expectLive(&.{ y, t }, sites.sites[0]) else try expectLive(&.{t}, sites.sites[0]);
    }
}

test "a hosted site is never a tail site" {
    var f = try Fixture.init();
    defer f.deinit();
    const t = try f.local();
    const ret = try f.stmt(.{ .ret = .{ .value = t } });
    const call = try f.call(t, f.hosted, ret);
    const p = try f.addProc(&.{}, call);

    var sites = try analyze(testing.allocator, &f.store, p);
    defer sites.deinit();
    try testing.expectEqual(@as(usize, 1), sites.sites.len);
    try testing.expect(!sites.sites[0].tail);
    try expectLive(&.{t}, sites.sites[0]);
}

test "a join's retained locals are live at a site before a jump to it" {
    var f = try Fixture.init();
    defer f.deinit();
    const r = try f.local();
    const t = try f.local();
    const param = try f.local();
    const join_id: LIR.JoinPointId = @fromBackingInt(@intCast(1));
    // join J(param) retained [r] = ret param in { t = seed(); param = t; jump J }
    const body = try f.stmt(.{ .ret = .{ .value = param } });
    const jump = try f.stmt(.{ .jump = .{ .target = join_id } });
    const pass = try f.set(param, t, jump);
    const call = try f.call(t, f.seed, pass);
    const join = try f.stmt(.{ .join = .{
        .id = join_id,
        .params = try f.store.addLocalSpan(&.{param}),
        .extra = try f.store.addOptionalStmtRow(LIR.JoinExtra, .{ .retained = try f.store.addLocalSpan(&.{r}) }),
        .body = body,
        .remainder = call,
    } });
    const p = try f.addProc(&.{r}, join);

    var sites = try analyze(testing.allocator, &f.store, p);
    defer sites.deinit();
    try testing.expectEqual(@as(usize, 1), sites.sites.len);
    try expectLive(&.{ r, t }, sites.sites[0]);
}

test "a value read after a loop's back edge is live at a site inside the loop" {
    var f = try Fixture.init();
    defer f.deinit();
    const acc = try f.local();
    const t = try f.local();
    const s = try f.local();
    const join_id: LIR.JoinPointId = @fromBackingInt(@intCast(1));
    // join L(acc) = { t = seed(); s = {acc, t}; acc = t; jump L } in { acc = acc0; jump L }
    // acc is read after the site on the same iteration; s is never read.
    const back = try f.stmt(.{ .jump = .{ .target = join_id } });
    const rebind = try f.set(acc, t, back);
    const build = try f.stmt(.{ .assign_struct = .{ .target = s, .fields = try f.store.addLocalSpan(&.{ acc, t }), .next = rebind } });
    const call = try f.call(t, f.seed, build);
    const acc0 = try f.local();
    const enter = try f.stmt(.{ .jump = .{ .target = join_id } });
    const init_acc = try f.set(acc, acc0, enter);
    const join = try f.stmt(.{ .join = .{ .id = join_id, .params = try f.store.addLocalSpan(&.{acc}), .body = call, .remainder = init_acc } });
    const p = try f.addProc(&.{acc0}, join);

    var sites = try analyze(testing.allocator, &f.store, p);
    defer sites.deinit();
    try testing.expectEqual(@as(usize, 1), sites.sites.len);
    try testing.expect(!sites.sites[0].tail);
    try expectLive(&.{ acc, t }, sites.sites[0]);
}

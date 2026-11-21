//! A platform's concurrency mode, from its header's `concurrency` field.

const std = @import("std");

/// What a hosted call may do while its result is not ready. design.md
/// "Suspendable Effects" says what each mode changes after checking.
pub const ConcurrencyMode = enum(u8) {
    /// Every hosted call completes before it returns. The default when the
    /// header has no `concurrency` field.
    none,
    /// A `suspending` hosted call may pause its task; one resume at a time.
    tasks,
    /// Like `tasks`, with tasks running on several threads at once.
    parallel_tasks,

    /// The mode a header's mode name denotes, or null for an unknown name.
    pub fn fromHeaderName(name: []const u8) ?ConcurrencyMode {
        if (std.mem.eql(u8, name, "None")) return .none;
        if (std.mem.eql(u8, name, "Tasks")) return .tasks;
        if (std.mem.eql(u8, name, "ParallelTasks")) return .parallel_tasks;
        return null;
    }
};

test "header names map to modes and nothing else does" {
    try std.testing.expectEqual(ConcurrencyMode.none, ConcurrencyMode.fromHeaderName("None").?);
    try std.testing.expectEqual(ConcurrencyMode.tasks, ConcurrencyMode.fromHeaderName("Tasks").?);
    try std.testing.expectEqual(ConcurrencyMode.parallel_tasks, ConcurrencyMode.fromHeaderName("ParallelTasks").?);
    try std.testing.expectEqual(@as(?ConcurrencyMode, null), ConcurrencyMode.fromHeaderName("tasks"));
    try std.testing.expectEqual(@as(?ConcurrencyMode, null), ConcurrencyMode.fromHeaderName("U64"));
}

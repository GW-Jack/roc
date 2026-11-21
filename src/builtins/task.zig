//! The task a `concurrency: Tasks` program runs in (design.md "Records And
//! The Task"). LIR reaches it only through the `task_*` low-level
//! operations, which read and write the fields below.

const std = @import("std");

/// One task. The runtime owns it; LIR holds a pointer to it with no
/// reference count. The runtime's own fields (the record chain, the root's
/// result storage) follow these when it exists.
pub const RocTask = extern struct {
    /// Nonzero while the task is paused on an operation that has not
    /// finished. Resuming clears it.
    pending: u8,
    /// Where a `suspending` hosted procedure writes its result.
    hosted_slot: [*]u8,
    /// Where a resumed record writes the result of a procedure that may
    /// suspend, and where its caller's resume entry reads it.
    result_buffer: [*]u8,

    /// `task_ready`: whether the pending flag is clear.
    pub fn ready(self: *const RocTask) bool {
        return self.pending == 0;
    }

    /// `task_set_pending`.
    pub fn setPending(self: *RocTask) void {
        self.pending = 1;
    }
};

test "the pending flag starts clear and is set by setPending" {
    var slot: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var task = RocTask{ .pending = 0, .hosted_slot = &slot, .result_buffer = &buffer };
    try std.testing.expect(task.ready());
    task.setPending();
    try std.testing.expect(!task.ready());
}

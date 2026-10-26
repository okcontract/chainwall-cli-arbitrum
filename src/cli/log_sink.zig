const c = @import("common.zig");
pub const Sink = struct {
    context: *anyopaque,
    consume: *const fn (*anyopaque, c.A, []const c.Value) anyerror!void,
    peak_bytes: usize = 0,
    records: usize = 0,
    pub fn accept(s: *Sink, a: c.A, values: []const c.Value) !void {
        try s.consume(s.context, a, values);
        s.records += values.len;
    }
};

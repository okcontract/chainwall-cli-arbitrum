const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const contracts = @import("contracts.zig");

pub const Outcome = struct {
    status: []const u8,
    queuedActions: []const []const u8,
    executedActions: []const []const u8,
    expiredActions: []const []const u8,
    skippedActions: []const []const u8,
};

/// Receipt success alone does not mean a governed change executed. Batch
/// execution can also expire or skip actions while its transaction succeeds.
pub fn classify(a: c.A, cat: contracts.Catalog, receipt: c.Value, instance: []const u8, method: contracts.Method, args: []const []const u8) !Outcome {
    var states: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (c.field(receipt, "logs")) |logs| {
        for (logs.array.items) |log| {
            if (!std.ascii.eqlIgnoreCase(try c.string(c.field(log, "address") orelse continue), instance)) continue;
            const topics = c.field(log, "topics") orelse continue;
            if (topics.array.items.len < 2) continue;
            for ([_][]const u8{ "ActionQueued", "ActionExecuted", "ActionExpired", "ActionCancelled" }) |name| {
                const event = cat.event(name) orelse continue;
                const topic = try c.hex(a, ms.bytecode.hash(try contracts.signature(a, event, false)));
                if (std.ascii.eqlIgnoreCase(try c.string(topics.array.items[0]), topic)) try states.put(a, try c.id(a, try c.string(topics.array.items[1])), name);
            }
        }
    }
    var queued: std.ArrayList([]const u8) = .empty;
    var executed: std.ArrayList([]const u8) = .empty;
    var expired: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (states.keys(), states.values()) |id, state| {
        if (c.eq(u8, state, "ActionQueued")) try queued.append(a, id);
        if (c.eq(u8, state, "ActionExecuted")) try executed.append(a, id);
        if (c.eq(u8, state, "ActionExpired")) try expired.append(a, id);
    }
    const batch = c.eq(u8, method.name, "executeActions");
    if (batch and args.len == 1) {
        var ids = std.mem.splitScalar(u8, std.mem.trim(u8, args[0], "[] \t\n"), ',');
        while (ids.next()) |raw| {
            const id = std.mem.trim(u8, raw, "\"' \t\n");
            if (id.len == 0) continue;
            const normalized = try c.id(a, id);
            if (!states.contains(normalized)) try skipped.append(a, normalized);
        }
    }
    const status: []const u8 = if (queued.items.len > 0) "queued" else if (batch and executed.items.len == 0) "no-actions-executed" else if (batch and (skipped.items.len > 0 or expired.items.len > 0)) "partial" else "confirmed";
    return .{ .status = status, .queuedActions = queued.items, .executedActions = executed.items, .expiredActions = expired.items, .skippedActions = skipped.items };
}

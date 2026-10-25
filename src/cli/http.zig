const std = @import("std");

/// Bound the complete request, including DNS, connection and body reads.
/// Cancellation joins both tasks before caller-owned buffers can be released.
pub fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
    return fetchWithTimeout(client, options, 60);
}
pub fn fetchWithTimeout(client: *std.http.Client, options: std.http.Client.FetchOptions, seconds: u32) !std.http.Client.FetchResult {
    const Result = union(enum) { response: std.http.Client.FetchError!std.http.Client.FetchResult, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(client.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ client.io, .fromSeconds(seconds), .awake });
    try select.concurrent(.response, std.http.Client.fetch, .{ client, options });
    return switch (try select.await()) {
        .response => |value| value,
        .timeout => |done| {
            try done;
            return error.HttpRequestTimeout;
        },
    };
}

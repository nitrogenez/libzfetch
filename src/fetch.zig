const std = @import("std");
const zstatus = @import("zstatus");

const Allocator = std.mem.Allocator;
const Pool = std.Thread.Pool;
const Uri = std.Uri;

const CliStatus = enum {
    fetching,
    failed,
    completed,
};

const status = zstatus.Notifier(CliStatus, 2, true, &[_]zstatus.ColorMap(CliStatus){
    .{ .key = .fetching, .value = .cyan },
    .{ .key = .failed, .value = .red },
    .{ .key = .completed, .value = .green },
});

pub const Fetcher = struct {
    pool: Pool,

    pub fn new(n_jobs: usize, allocator: Allocator) Fetcher {
        var self = Fetcher{ .pool = undefined };
        try self.pool.init(.{ .allocator = allocator, .n_jobs = n_jobs });
        return self;
    }

    pub fn deinit(self: *Fetcher) void {
        self.pool.deinit();
    }

    pub fn add(self: *Fetcher, allocator: Allocator, url: []const u8, out_stream: anytype) !void {
        try self.pool.spawn(struct {
            fn func() void {
                fetch(allocator, url, out_stream) catch |err|
                    status.notify(.failed, "{!}", .{err});
            }
        }.func, .{});
    }
};

pub const Target = struct {
    url: Uri,
    size: ?u64,
    ready: u64 = 0,
    client: std.http.Client = undefined,
    request: std.http.Client.Request = undefined,
    header_buffer: [1024 * 8]u8 = undefined,

    pub fn new(url: Uri) Target {
        return Target{
            .url = url,
            .size = null,
        };
    }

    pub fn fromUrl(url: []const u8) !Target {
        return Target{
            .url = try Uri.parse(url),
            .size = null,
        };
    }

    pub fn start(self: *Target, allocator: std.mem.Allocator) !void {
        self.client = std.http.Client{ .allocator = allocator };
        self.request = try self.client.open(.GET, self.url, .{
            .server_header_buffer = &self.header_buffer,
        });
        try self.request.send();
        try self.request.wait();

        if (self.request.response.content_length) |content_length|
            self.size = content_length;
    }

    pub fn streamBlock(self: *Target, out_stream: anytype) !usize {
        var block: [1024]u8 = undefined;
        const bytes = try self.request.read(&block);
        try out_stream.writeAll(block[0..bytes]);
        self.ready += bytes;
        return bytes;
    }

    pub fn finish(self: *Target) void {
        try self.request.finish();
        self.request.deinit();
        self.client.deinit();
    }
};

pub fn fetch(allocator: Allocator, url: []const u8, out_stream: anytype) !void {
    status.notify(.fetching, "{s}...", .{std.fs.path.basename(url)});

    var target = try Target.fromUrl(url, out_stream);
    try target.start(allocator);
    defer target.finish();
    const total = if (target.size) |size| size else std.math.maxInt(usize);

    while (target.ready < total)
        if (try target.streamBlock(out_stream) == 0) break;
}

test {
    std.testing.refAllDecls(@This());
}

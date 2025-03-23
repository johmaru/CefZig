
const std = @import("std");
const ws = @import("websocket");
const curl = @cImport({
    @cInclude("curl/curl.h");
});
const chromium_downloader = @import("lib/chromium_downloader.zig");

pub const ChromiumBrowser = struct {
    websocket: *WebSocketConnection,
    is_connected: bool,
    settings: BrowserSettings,
    local_mode: LocalBrowserMode,

    event_listener: std.ArrayList(EventListener),

    const Self = @This();

    pub fn init(allocator :std.mem.Allocator,settings: BrowserSettings) !Self {
        var websocket_conn = try WebSocketConnection.init(settings.url,allocator, settings.port);
        return Self{
            .websocket = &websocket_conn,
            .settings = settings,
            .is_connected = false,
            .event_listener = std.ArrayList(EventListener).init(),
            .local_mode = settings.local_mode,
        };
    }

    pub fn run(self: *Self) !void {
        if (self.local_mode == LocalBrowserMode.Download){


        } else if (self.local_mode == LocalBrowserMode.Embedded){
            try self.websocket.connect();
        }
    }
};

pub const BrowserSettings = struct {
    url: []const u8,
    session_id: []const u8,
    port: ?u16 = 9222,
    local_mode: LocalBrowserMode,
};

pub const EventListener = struct {
    event_type: EventType,
    callback: fn(EventListener, ChromiumBrowser, []const u8) void,
};

pub const EventType = enum {
    OnConnected,
    OnDisconnected,
    OnMessage,
};

pub const LocalBrowserMode = enum {
    Download,
    Embedded,
};

pub const WebSocketConnection = struct {
    url: []const u8,
    socket: ?ws.Client = null,
    allocator: std.mem.Allocator,
    port: u16 = 9222,

    is_connected: bool,

    const Self = @This();

    pub fn init(url: []const u8, gpa: std.mem.Allocator,port: ?u16) !Self {
        const allocator = gpa.allocator();
        return Self{ 
            .url = url,
            .allocator = allocator,
            .is_connected = false,
            .port = port orelse 9222,
        };
    }

    pub fn connect(self: *Self) !void {
        if (self.is_connected) return;

        self.socket = try ws.Client.init(self.allocator, .{
            .port = self.port,
            .host = "localhost"
        });
        defer self.socket.deinit();
    }
};

fn getDebuggerUrl(allocator: std.mem.Allocator, port: u16) ![]const u8 {
    _ = curl.curl_global_init(curl.CURL_GLOBAL_ALL);
    defer curl.curl_global_cleanup();

    const curl_handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(curl_handle);

    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    const writeCallBack = struct {
        fn callback(data: [*c]u8, size: c_uint, nmemb: c_uint, user_data: ?*anyopaque) callconv(.C) c_uint {
            const response_ptr = @as(*std.ArrayList(u8), @ptrCast(@alignCast(user_data)));
            const real_size = size * nmemb;
            response_ptr.appendSlice(data[0..real_size]) catch return 0;
            return real_size;
        }
    }.callback;

    const url = try std.fmt.AllocPrint(allocator, "http://localhost:{d}/json", .{port});
    defer allocator.free(url);

    _ = curl.curl_easy_setopt(curl_handle, curl.CURLOPT_URL, url);
    _ = curl.curl_easy_setopt(curl_handle, curl.CURLOPT_WRITEFUNCTION, writeCallBack);
    _ = curl.curl_easy_setopt(curl_handle, curl.CURLOPT_WRITEDATA, &response);

    const res = curl.curl_easy_perform(curl_handle);
    if (res != curl.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.items,.{});
    defer parsed.deinit();

    if (parsed.value.array.items.len > 0){
        const first = parsed.value.array.items[0];
        if (first.object.get("webSocketDebuggerUrl")) |value| {
            return allocator.dupe(u8, value.string);
        }
    }

    return error.NoDebuggerUrlFound;
}

test "download chromium" {
    const allocator = std.heap.page_allocator;
    var downloader = try chromium_downloader.ChromiumDownloader.init(allocator);
    try downloader.download();
    try downloader.unzip();
}
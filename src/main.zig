
const std = @import("std");
const ws = @import("websocket");
const curl = @cImport({
    @cInclude("curl/curl.h");
});
const chromium_downloader = @import("lib/chromium_downloader.zig");
const builtin = @import("builtin");

pub const ChromiumBrowser = struct {
    websocket: WebSocketConnection,
    websocket_mutex: std.Thread.Mutex = .{},
    is_connected: bool,
    settings: BrowserSettings,
    local_mode: LocalBrowserMode,
    process: ?std.process.Child = null,
    should_quit: bool = false,

    event_listener: std.ArrayList(EventListener),
    next_message_id: i64 = 1,

    const Self = @This();

    const EventLoopContext = struct {
        allocator: std.mem.Allocator,
        browser: *Self,
    };

    pub fn init(allocator :std.mem.Allocator,settings: BrowserSettings) !Self {
        const websocket_conn = try WebSocketConnection.init(settings.url,allocator, settings.port);
        return Self{
            .websocket = websocket_conn,
            .settings = settings,
            .is_connected = false,
            .event_listener = std.ArrayList(EventListener).init(allocator),
            .local_mode = settings.local_mode,
            .process = null,
            .should_quit = false,
        };
    }

    pub fn deinit(self: *Self) !void {
        if (self.process) |*process| {
          _= try process.kill();
        }

        self.should_quit = true;

        if (self.websocket.is_connected) {
            {
                self.websocket_mutex.lock();
                defer self.websocket_mutex.unlock();
                self._injectQuitHandlerWithoutLock(self.websocket.allocator) catch |err| {
                std.debug.print("Error injecting quit handler: {s}\n", .{@errorName(err)});
            };
            }

            {
                self.websocket_mutex.lock();
                defer self.websocket_mutex.unlock();

                self.dispatchEvent(.OnQuit, "window.__ZIG_QUIT()") catch |err| {
                std.debug.print("Error dispatching quit event: {s}\n", .{@errorName(err)});
                };
            }
        }

        std.time.sleep(500 * std.time.ns_per_ms);
        
        if (self.websocket.socket) |*socket| {
            socket.deinit();
        }
    

        std.debug.print("Deinitializing browser...\n", .{});

        self.event_listener.deinit();
    }

    pub fn run(self: *Self) !void {
        if (self.local_mode == LocalBrowserMode.Download){
            const alocator = std.heap.page_allocator;
            switch (builtin.os.tag) {
                .windows => {
                    launchChromium(alocator,"chromium\\chrome-win\\chrome.exe", self.settings.port,self) catch |err| {
                        std.debug.print("Error launching chromium: {s}\n", .{@errorName(err)});
                        return err;
                    };
                },
                .linux => {
                    launchChromium(alocator,"chromium/chrome-linux/chrome", self.settings.port,self) catch |err| {
                        std.debug.print("Error launching chromium: {s}\n", .{@errorName(err)});
                        return err;
                    };
                },
                else => {
                    return error.UnsupportedPlatform;
                }
           }

            std.time.sleep(1 * std.time.ns_per_s);

            const url = try getDebuggerUrl(self.websocket.allocator, self.settings.port.?);
            defer self.websocket.allocator.free(url);
            self.websocket.url = url;

            try self.websocket.connect();
            self.is_connected = true;

            try self.startEventLoop(self.websocket.allocator);

        } 
        else if (self.local_mode == LocalBrowserMode.Embedded){
            try self.websocket.connect();
            self.is_connected = true;
            try self.startEventLoop(self.websocket.allocator);
        }

    }

    pub fn launchChromium(allocator: std.mem.Allocator,executable_path: []const u8,debugport: ?u16,self:* Self)  !void {

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(executable_path);
        try args.append(try std.fmt.allocPrint(allocator, "--remote-debugging-port={?}", .{debugport}));
        try args.append("--disable-gpu");

        if (self.settings.headless orelse false) {
            try args.append("--headless=new");
        }

        var to_free = std.ArrayList([]const u8).init(allocator);
        defer {
            for (to_free.items) |item| {
                allocator.free(item);
            }
            to_free.deinit();
        }

        try to_free.append(args.items[1]);

        var child = std.process.Child.init(args.items, allocator);

        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        std.time.sleep(1 * std.time.ns_per_s);

        self.process = child;

        return;
    }

    fn runEventLoop(self: *Self, allocator: std.mem.Allocator) !void {
        const timeout_ms = 500;
        
        try self.websocket.socket.?.readTimeout(timeout_ms * std.time.ns_per_ms);

        while (!self.should_quit) {

       
            self.websocket_mutex.lock();
            const response = self.websocket.socket.?.read() catch |err| {
                self.websocket_mutex.unlock();

                if (err == error.WouldBlock or err == error.TimedOut or err == error.Timeout) {
                
                    std.time.sleep(50 * std.time.ns_per_ms);
                    continue;
                }

                std.debug.print("Error reading from websocket: {s}\n", .{@errorName(err)});
                return err;
            };
            self.websocket_mutex.unlock();
            
            if (response) |data| {
                
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data.data, .{});
                defer parsed.deinit();
                
            
                if (parsed.value.object.get("method")) |method| {
                    if (std.mem.eql(u8, method.string, "Page.loadEventFired")) {
                        try self.dispatchEvent(.OnMessage, data.data);
                    } else if (std.mem.eql(u8, method.string, "Runtime.consoleAPICalled")) {
                        
                        try self.dispatchEvent(.OnMessage, data.data);
                    }
                }
                
                if (parsed.value.object.get("customEvent")) |custom_event| {
                    if (std.mem.eql(u8, custom_event.string, "quit")) {
                        try self.dispatchEvent(.OnQuit, data.data);
                        self.should_quit = true;
                    }
                }
            }
            
            std.time.sleep(100 * std.time.ns_per_ms);
        
        }
    }

    fn eventLoopThreadFn(ctx: *EventLoopContext) void {
        defer ctx.allocator.destroy(ctx);

        ctx.browser.runEventLoop(ctx.allocator) catch |err| {
            std.debug.print("Error in event loop: {s}\n", .{@errorName(err)});
        };
    }

    pub fn startEventLoop(self: *Self, allocator: std.mem.Allocator) !void {
       
        if (self.websocket.socket == null) {
            return error.WebSocketNotConnected;
        }
    
        if (!self.websocket.is_connected) {
            return error.WebSocketNotConnected;
        }
    
        const ctx = try allocator.create(EventLoopContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = self,
        };

        _ = try std.Thread.spawn(.{}, eventLoopThreadFn, .{ctx});
    }

    pub fn evaluateJS(self: *Self, allocator: std.mem.Allocator,expression: []const u8) ![]const u8 {
       if (!self.websocket.is_connected) return error.NotConnected;

        self.websocket_mutex.lock();
        defer self.websocket_mutex.unlock();

        const message_id = self.next_message_id;
        self.next_message_id += 1;

        const message = try std.fmt.allocPrint(
            allocator, 
            "{{\"id\":{d},\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":\"{s}\"}}}}", 
            .{message_id, expression}
        );
        defer allocator.free(message);

        try self.websocket.socket.?.write(message);

        const start_time = std.time.milliTimestamp();
        const timeout_ms = 5000;
    
        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            if (try self.websocket.socket.?.read()) |response| {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.data, .{});
                defer parsed.deinit();
            
            if (parsed.value.object.get("id")) |id| {
                if (id.integer == message_id) {
                    if (parsed.value.object.get("result")) |result| {
                        if (result.object.get("result")) |inner_result| {
                            if (inner_result.object.get("value")) |value| {
                                return allocator.dupe(u8, value.string);
                            }
                        }
                    }
                    return error.InvalidResponse;
                }
            }
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
        return error.Timeout;
    }

    pub fn injectQuitHandler(self: *Self, allocator: std.mem.Allocator) !void {
        const js_code = 
            \\window.__ZIG_QUIT = function() {
            \\  window.chrome.webSocketDebuggerSend({
            \\    customEvent: 'quit'
            \\  });
            \\};
            \\console.log('Quit handler injected. Call window.__ZIG_QUIT() to exit');
        ;
    
        _ = try self.evaluateJS(allocator, js_code);
    }

    fn _injectQuitHandlerWithoutLock(self: *Self, allocator: std.mem.Allocator) !void {
        const js_code = 
            \\window.__ZIG_QUIT = function() {
            \\  window.chrome.webSocketDebuggerSend({
            \\    customEvent: 'quit'
            \\  });
            \\};
            \\console.log('Quit handler injected. Call window.__ZIG_QUIT() to exit');
        ;

        const message_id = self.next_message_id;
        self.next_message_id += 1;

        const message = try std.fmt.allocPrint(
            allocator, 
            "{{\"id\":{d},\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":\"{s}\"}}}}", 
            .{message_id, js_code}
        );
        defer allocator.free(message);

        try self.websocket.socket.?.write(message);
    }

    pub fn addEventListener(self: *Self, event_type: EventType, callback: *const fn(EventListener, *ChromiumBrowser, []const u8) void) !void {
        const listener = EventListener{
            .event_type = event_type,
            .callback = callback,
        };
        try self.event_listener.append(listener);
    }

    pub fn dispatchEvent(self: *Self, event_type: EventType, message: []const u8) !void {
        for (self.event_listener.items) |*listener| {
            if (listener.event_type == event_type) {
                listener.callback(listener.*, self, message);
            }
        }
    }

    pub fn navigate(self: *Self,allocator: std.mem.Allocator, url: []const u8) !void {
        if (!self.websocket.is_connected) return error.NotConnected;
        self.websocket_mutex.lock();
        defer self.websocket_mutex.unlock();

        const message_id = self.next_message_id;
        self.next_message_id += 1;

        const message = try std.fmt.allocPrint(
            allocator, 
            "{{\"id\":{d},\"method\":\"Page.navigate\",\"params\":{{\"url\":\"{s}\"}}}}", 
            .{message_id, url}
        );
        defer allocator.free(message);

        try self.websocket.socket.?.write(message);

        const start_time = std.time.milliTimestamp();
        const timeout_ms = 5000;
        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            if (try self.websocket.socket.?.read()) |response| {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.data, .{});
                defer parsed.deinit();
            
            if (parsed.value.object.get("id")) |id| {
                if (id.integer == message_id) {
                    return;
                }
            }
        }
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }

    pub fn mouseClick(self: *Self, allocator: std.mem.Allocator, x: f64, y: f64) !void {
        const message_id = self.next_message_id;
        self.next_message_id += 1;

        {
            const down_msg = try std.fmt.allocPrint(
                allocator, 
                "{{\"id\":{d},\"method\":\"Input.dispatchMouseEvent\",\"params\":{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}}}", 
                .{message_id, x, y}
            );
            defer allocator.free(down_msg);
            try self.websocket.socket.?.write(down_msg);
        }

        {
            const up_msg = try std.fmt.allocPrint(
                allocator, 
                "{{\"id\":{d},\"method\":\"Input.dispatchMouseEvent\",\"params\":{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}}}",  
                .{message_id, x, y}
            );
            self.next_message_id += 1;
            defer allocator.free(up_msg);
            try self.websocket.socket.?.write(up_msg);
        }
    }

    pub fn typeText(self: *Self, allocator: std.mem.Allocator, text: []const u8) !void {
        const message_id = self.next_message_id;
        self.next_message_id += 1;

        const message = try std.fmt.allocPrint(
            allocator, 
            "{{\"id\":{d},\"method\":\"Input.insertText\",\"params\":{{\"text\":\"{s}\"}}}}",  
            .{message_id, text}
        );
        defer allocator.free(message);

        try self.websocket.socket.?.write(message);
    }

    pub fn clickElement(self: *Self, allocator: std.mem.Allocator, selector: []const u8) !void {
        const js_cmd = try std.fmt.allocPrint(
            allocator, 
            "document.querySelector(\"{s}\").click();", 
            .{selector}
        );
        defer allocator.free(js_cmd);

        _ = try self.evaluateJS(allocator, js_cmd);
    }

};

pub const BrowserSettings = struct {
    url: []const u8,
    session_id: []const u8,
    port: ?u16 = 9222,
    local_mode: LocalBrowserMode,
    headless: ?bool = true,
};

pub const EventListener = struct {
    event_type: EventType,
    callback: *const fn(EventListener, *ChromiumBrowser, []const u8) void,
};

pub const EventType = enum {
    OnConnected,
    OnDisconnected,
    OnMessage,
    OnJSEval,
    OnQuit,
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
        return Self{ 
            .url = url,
            .allocator = gpa,
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
       
        const path = if (std.mem.indexOf(u8, self.url, "://")) |pos| blk: {
        const after_protocol = self.url[pos + 3..];
        if (std.mem.indexOf(u8, after_protocol, "/")) |slash_pos| {
            break :blk after_protocol[slash_pos..];
        }
            break :blk "/";
        } else "/";

        try self.socket.?.handshake(path, .{ 
            .timeout_ms = 5000,
            .headers = try std.fmt.allocPrint(self.allocator, "Host: localhost:{d}", .{self.port})
        });

        self.is_connected = true;

    }
};

pub fn getDebuggerUrl(allocator: std.mem.Allocator, port: u16) ![]const u8 {

    var client = std.http.Client{
        .allocator = allocator
    };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/json", .{port});
    defer allocator.free(url);
    const uri = try std.Uri.parse(url);

    var buffer: [32 * 1024]u8 = undefined;
    var response = try client.open(.GET,uri, .{
        .server_header_buffer = &buffer,
    });
    defer response.deinit();
    response.send() catch |err| {
        std.debug.print("HTTP REQUEST SEND ERROR: {s}\n", .{@errorName(err)});
        return err;
    };

    response.wait() catch |err| {
        std.debug.print("HTTP REQUEST WAIT ERROR: {s}\n", .{@errorName(err)});
        return err;
    };
    response.finish() catch |err| {
        std.debug.print("HTTP REQUEST FINISH ERROR: {s}\n", .{@errorName(err)});
        return err;
    };
    if (response.response.status != std.http.Status.ok) {
        std.debug.print("Server has returned status code {d}\n", .{response.response.status});
        return error.UnexpectedStatusCode;
    }
   

    var body_buffer = std.ArrayList(u8).init(allocator);
    defer body_buffer.deinit();

    try response.reader().readAllArrayList(&body_buffer, 32 * 1024);


    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_buffer.items,.{});
    defer parsed.deinit();

    if (parsed.value.array.items.len > 0){
        for (parsed.value.array.items) |item| {
        if (item.object.get("type")) |type_value| {
            if (std.mem.eql(u8, type_value.string, "page")) {
                if (item.object.get("webSocketDebuggerUrl")) |value| {
                    return allocator.dupe(u8, value.string);
                }
            }
        }
    }
    }

    return error.NoDebuggerUrlFound;
}

fn onJSResult(
    _ : EventListener,
    _: *ChromiumBrowser,
    message: []const u8,
) void {
    std.debug.print("JS Result: {s}\n", .{message});
}

pub const BrowserDevToolsUrl = struct {
    const chromium_url : []const u8 = "ws://localhost:9222/devtools/browser";
};

test "run chromium downloader" {
    // Set the console output to UTF-8
    if (builtin.os.tag == .windows) {
       _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }

    const allocator = std.heap.page_allocator;

    // this code is auto download the chromium browser
    
    // var downloader = try chromium_downloader.ChromiumDownloader.init(allocator);
    // try downloader.download();
    // try downloader.unzip(.{.replace = true});

    // const ziptest = try chromium_downloader.lookup_zip(allocator);
    // defer allocator.free(ziptest);

    // for (ziptest) |zippath| {
    //     std.debug.print("Found zip file: {s}\n", .{zippath});
    // }


    // need to run the chromium downloader
    // port is can any port
    // url is the url of the chromium browser
    var browser = try ChromiumBrowser.init(allocator, .{
        .local_mode = LocalBrowserMode.Download,
        .port = 9222,
        .url = BrowserDevToolsUrl.chromium_url,
        .session_id = "123456",
        .headless = false,
    });

    // run the browser
    browser.run() catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        return err;
    };

   defer browser.deinit() catch |err| {
        std.debug.print("Error deinitializing browser: {s}\n", .{@errorName(err)});
    };

    // add an event listener for the OnJSEval event
    try browser.addEventListener(EventType.OnJSEval, onJSResult);

    // evaluate some js
    const result = try browser.evaluateJS(allocator, "document.title");
    defer allocator.free(result);

    // navigate to a url
    browser.navigate(allocator, "https://www.google.co.jp/") catch |err| {
        std.debug.print("Error navigating: {s}\n", .{@errorName(err)});
        return err;
    };

    // dispatch the event
    try browser.dispatchEvent(.OnJSEval, result);
   
    std.debug.print("Result: {s}\n", .{result});

    std.debug.print("Done\n", .{});


}
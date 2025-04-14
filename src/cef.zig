
const std = @import("std");
const ws = @import("websocket");
const curl = @cImport({
    @cInclude("curl/curl.h");
});
const proto = ws.proto;
const chromium_downloader = @import("lib/chromium_downloader.zig");
const builtin = @import("builtin");

pub const ChromiumBrowser = struct {
    websocket: WebSocketConnection,
    temp_websocket: ?WebSocketConnection = null,
    is_switching_connection: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    paused_for_eval: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event_loop_terminated: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event_loop_is_safe_to_terminate: std.atomic.Value(bool),
    event_loop_thread: ?std.Thread = null,
    websocket_mutex: std.Thread.Mutex = .{},
    is_connected: bool,
    settings: BrowserSettings,
    state: BrowserState,
    local_mode: LocalBrowserMode,
    process: ?std.process.Child = null,
    should_quit: bool = false,
    auto_open_devtools: bool = false,
    connection_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    event_loop_force_quit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    current_thread_version: u64 = 0,
    write_queue: std.ArrayList(*WriteQueueItem),
    write_queue_mutex: std.Thread.Mutex = .{},
    read_queue: std.ArrayList(*ReadQueueItem),
    read_queue_mutex: std.Thread.Mutex = .{},
    connection_queues: std.AutoHashMap(u64, ConnectionQueue),
    connection_queues_mutex: std.Thread.Mutex = .{},

    event_listener: std.ArrayList(EventListener),
    next_message_id: i64 = 1,

    const Self = @This();

    const EventLoopContext = struct {
        allocator: std.mem.Allocator,
        browser: *Self,
        initial_connection_version: u64,
    };

    pub fn init(allocator :std.mem.Allocator,settings: BrowserSettings) !Self {
        const websocket_conn = try WebSocketConnection.init(settings.url,allocator, settings.port);
        var connection_queues = std.AutoHashMap(u64, ConnectionQueue).init(allocator);

        connection_queues.put(websocket_conn.connection_id, ConnectionQueue{
            .write_queue = std.ArrayList(*WriteQueueItem).init(allocator),
            .read_queue = std.ArrayList(*ReadQueueItem).init(allocator),
            .mutex = std.Thread.Mutex{},
        }) catch |err| {
            std.debug.print("Error initializing connection queues: {s}\n", .{@errorName(err)});
            return err;
        };

        return Self{
            .websocket = websocket_conn,
            .settings = settings,
            .is_connected = false,
            .event_listener = std.ArrayList(EventListener).init(allocator),
            .local_mode = settings.local_mode,
            .process = null,
            .should_quit = false,
            .auto_open_devtools = settings.auto_open_devtools orelse false,
            .state = try BrowserState.init(allocator),
            .is_switching_connection = std.atomic.Value(bool).init(false),
            .event_loop_is_safe_to_terminate = std.atomic.Value(bool).init(true),
            .write_queue = std.ArrayList(*WriteQueueItem).init(allocator),
            .read_queue = std.ArrayList(*ReadQueueItem).init(allocator),
            .connection_queues = connection_queues,
            .connection_queues_mutex = std.Thread.Mutex{},
            .event_loop_thread = null,
        };
    }

   pub fn deinit(self: *Self) !void {
    std.debug.print("Initiating browser deinitialization...\n", .{});

    self.should_quit = true;
    
    self.event_loop_force_quit.store(true, .seq_cst);

    std.debug.print("Waiting for event loop thread to join...\n", .{});
        if (self.event_loop_thread) |thread| {
            
            thread.join();
            std.debug.print("Event loop thread joined.\n", .{});
            self.event_loop_thread = null; 
        } else {
            std.debug.print("No active event loop thread found to join.\n", .{});
        }

    if (self.process) |*process| {
        std.debug.print("Terminating browser process...\n", .{});
            _ = process.kill() catch |kill_err| {
                std.debug.print("Failed to kill process: {s}\n", .{@errorName(kill_err)});
            };
        self.process = null; 
    }

    std.debug.print("Deinitializing WebSocket connection...\n", .{});
    {
        self.websocket_mutex.lock();
        defer self.websocket_mutex.unlock();

        std.debug.print("Calling websocket.deinit()...\n", .{});
        self.websocket.deinit();
        std.debug.print("websocket.deinit() finished.\n", .{});
        if (self.temp_websocket) |*temp_ws| {
                 std.debug.print("Deinitializing temporary websocket (ID: {d})...\n", .{temp_ws.connection_id});
                 temp_ws.deinit();
                 self.temp_websocket = null;
            }
    }
     std.debug.print("WebSocket connection deinitialized.\n", .{});

    std.debug.print("Cleaning up queues, listeners, and state...\n", .{});

    self.connection_queues_mutex.lock();
    defer self.connection_queues_mutex.unlock();

    std.debug.print("Locked connection_queues_mutex for cleanup.\n", .{});

    var iter = self.connection_queues.iterator();
    while (iter.next()) |entry| {
            std.debug.print("Cleaning queue for connection ID: {d}\n", .{entry.key_ptr});
            entry.value_ptr.mutex.lock();

            while (entry.value_ptr.write_queue.items.len > 0) {
               const item_ptr_optinal = entry.value_ptr.write_queue.pop();
                const item_ptr = item_ptr_optinal.?;
               item_ptr.deinit();
               self.websocket.allocator.destroy(item_ptr);
           }
           entry.value_ptr.write_queue.deinit(); 

           while (entry.value_ptr.read_queue.items.len > 0) {
               const item_ptr_optinal = entry.value_ptr.read_queue.pop();
               const item_ptr = item_ptr_optinal.?;
               item_ptr.deinit();
               self.websocket.allocator.destroy(item_ptr);
           }
           entry.value_ptr.read_queue.deinit(); 

            entry.value_ptr.mutex.unlock(); 
            std.debug.print("Finished cleaning queue for connection ID: {d}\n", .{entry.key_ptr});
        }
    self.connection_queues.deinit(); 

    self.event_listener.deinit();
    self.state.deinit(); 

    std.debug.print("Browser deinitialization complete.\n", .{});

}
    /// Run the browser in local mode (downloaded Chromium) or embedded mode (CEF)
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

            const url = getDebuggerUrl(self.websocket.allocator, self.settings.port.?) catch |err| {
                std.debug.print("Error getting debugger URL: {s}\n", .{@errorName(err)});
                return err;
            };
            defer self.websocket.allocator.free(url);
            
            getTabInfo(self.websocket.allocator, self.settings.port.?, self) catch |err| {
                std.debug.print("Error getting tab info: {s}\n", .{@errorName(err)});
                return err;
            };

            std.debug.print("Debug: Selected WebSocket URL: {s}\n", .{url});
            
            self.websocket.url = url;

            self.websocket.connect() catch |err| {
                std.debug.print("Error connecting to websocket: {s}\n", .{@errorName(err)});
                return err;
            };
            self.is_connected = true;

            
            std.Thread.sleep(std.time.ns_per_ms * 1000);

            if (!self.websocket.is_connected) {
                return error.WebSocketConnectionFailed;
            }
            
            self.startEventLoop(self.websocket.allocator) catch |err| {
                std.debug.print("Error starting event loop: {s}\n", .{@errorName(err)});
                return err;
            };
            
            std.debug.print("Browser initiated and event loop started. Ready for commands.\n", .{});
            
            var retry_count: usize = 0;
            const max_retries: usize = 20;
            
            while (retry_count < max_retries) {
                if (self.websocket.is_connected and self.websocket.socket != null and !self.is_switching_connection.load(.seq_cst)) {
                    std.debug.print("WebSocket connection established and ready (attempt {d})\n", .{retry_count});
                    break;
                }

                std.debug.print("Waiting for WebSocket connection to stabilize (attempt {d}/{d})\n",
                    .{retry_count + 1, max_retries});
                std.time.sleep(100 * std.time.ns_per_ms); 
                retry_count += 1;

                if (retry_count >= max_retries) {
                    std.debug.print("WARNING: Connection might not be fully established yet\n", .{});
                }
            }
            
        } 
        else if (self.local_mode == LocalBrowserMode.Embedded){
            try self.websocket.connect();
            self.is_connected = true;
            _ = self.connection_version.fetchAdd(1, .seq_cst);
            
            self.startEventLoop(self.websocket.allocator) catch |err| {
                std.debug.print("Error starting event loop: {s}\n", .{@errorName(err)});
                return err;
            };
            
            std.debug.print("Browser initiated and event loop started in embedded mode. Ready for commands.\n", .{});
        }
        
    }

    pub fn close(self: *Self) !void {
       self.deinit() catch |err| {
            std.debug.print("Error closing browser: {s}\n", .{@errorName(err)});
        };
    }
    // Launch Chromium with the specified executable path and port
    pub fn launchChromium(allocator: std.mem.Allocator,executable_path: []const u8,debugport: ?u16,self:* Self)  !void {

        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(executable_path);
        try args.append(try std.fmt.allocPrint(allocator, "--remote-debugging-port={?}", .{debugport}));
        try args.append("--disable-gpu");

        if (self.settings.headless orelse false) {
            try args.append("--headless=new");
        }
        
        if (self.auto_open_devtools) {
            try args.append("--auto-open-devtools-for-tabs");
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

    /// Wait for the event loop to terminate, with a timeout
    pub fn waitForEventLoopTermination(self: *Self) !void {
        const max_wait_ms = 5000;
        const check_interval_ms: u64 = 50;
        const start_time = std.time.milliTimestamp();
        var waited_ms: i64 = 0;

        while (!self.event_loop_terminated.load(.seq_cst)) {
            waited_ms = std.time.milliTimestamp() - start_time;
            if (waited_ms >= max_wait_ms) {
                std.debug.print("waitForEventLoopTermination: Timeout after {d}ms\n", .{waited_ms});
                return error.EventLoopTerminationTimeout;
            }
            std.time.sleep(check_interval_ms * std.time.ns_per_ms);
        }

        return error.EventLoopTerminationTimeout;
    }
    // Start the WebSocket loop in a new thread
    pub fn startWebSocketLoop(self: Self) !void {
        const thread = try self.websocket.socket.?.readLoopInNewThread(self.websocket.socket);
        thread.detach();
    }
    // Run the event loop in a separate thread
    fn runEventLoop(ctx: *EventLoopContext) !void {

        defer ctx.allocator.destroy(ctx);
        const self = ctx.browser;
        const allocator = ctx.allocator;

        self.current_thread_version = ctx.initial_connection_version;

        std.debug.print(">>> EVENT LOOP START - THREAD ID: {any} - VERSION: {d} <<<\n",
            .{std.Thread.getCurrentId(), self.current_thread_version});
        
        if (self.websocket.socket == null) {
            std.debug.print("WebSocket socket is null in event loop\n", .{});
             self.event_loop_terminated.store(true, .seq_cst);
            return;
        }

        // Current thread version saved for this thread
        self.current_thread_version = self.connection_version.load(.seq_cst);
        std.debug.print("Event loop started with connection version: {d}\n", .{self.current_thread_version});
        
        if (self.event_loop_terminated.load(.seq_cst)) {
            std.debug.print("Event loop was already terminated, exiting\n", .{});
            self.event_loop_terminated.store(false, .seq_cst);
        }
        while (!self.should_quit and !self.event_loop_force_quit.load(.seq_cst)) {
            std.debug.print("Test -- Now Thread Version {d}\n", .{self.current_thread_version});

            const current_live_version = self.connection_version.load(.seq_cst);
            if (current_live_version != self.current_thread_version) {
                std.debug.print("Connection version changed ({d} -> {d}), terminating event loop\n",
                .{self.current_thread_version, current_live_version});
                self.event_loop_terminated.store(true, .seq_cst);
                return;
            }

            if (self.event_loop_force_quit.load(.seq_cst)) {
               std.debug.print("Event loop force quit signal received\n", .{});
            
                const safety_timeout_ms = 1000;
                const safety_start_time = std.time.milliTimestamp();
            
                while (!self.event_loop_is_safe_to_terminate.load(.seq_cst)) {
                    if (std.time.milliTimestamp() - safety_start_time > safety_timeout_ms) {
                        std.debug.print("Safety timeout exceeded, forcing event loop termination\n", .{});
                        break;
                    }
                std.time.sleep(10 * std.time.ns_per_ms);
                }
        
                if (self.websocket_mutex.tryLock()) {
                    self.websocket_mutex.unlock();
                }
            
                self.event_loop_terminated.store(true, .seq_cst);
                std.debug.print("Event loop terminated successfully\n", .{});
                return;
            }

            // Check if the connection version has changed
            const current_version = self.connection_version.load(.seq_cst);
            if (current_version != self.current_thread_version) {
                std.debug.print("Connection version changed ({d} -> {d}), terminating event loop\n",
                    .{self.current_thread_version, current_version});
                self.event_loop_terminated.store(true, .seq_cst);
                return;
            }

            {
                self.event_loop_is_safe_to_terminate.store(false, .seq_cst);
                self.websocket_mutex.lock();
                defer self.websocket_mutex.unlock();
                const socket_valid = self.websocket.socket != null and self.websocket.is_connected;

                if (!socket_valid) {
                    std.debug.print("WebSocket no longer valid, terminating event loop\n", .{});
                    self.event_loop_terminated.store(true, .seq_cst);
                    return;
                }

                if (self.paused_for_eval.load(.seq_cst)) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                }

                if (!socket_valid) {
                    std.debug.print("WebSocket has been disconnected, pausing event loop\n", .{});
                    std.time.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                std.debug.print("DEBUG : Exit 1 Branket Scoop\n", .{});
                self.event_loop_is_safe_to_terminate.store(true, .seq_cst);
            }

            {
                const current_id = self.websocket.connection_id;
                std.debug.print("Checking queue for connection ID: {d}\n", .{current_id});
                self.connection_queues_mutex.lock();
                const maybe_queue_ptr = self.connection_queues.getPtr(current_id);
                self.connection_queues_mutex.unlock();

                if (maybe_queue_ptr) |queue_ptr| {
                    std.debug.print("Attempting to lock write queue mutex (ID: {d})...\n", .{current_id});
                    if (queue_ptr.*.mutex.tryLock()) {
                        std.debug.print("Write queue mutex locked (ID: {d}). Queue length: {d}\n", .{current_id, queue_ptr.*.write_queue.items.len});
                        defer std.debug.print("Write queue mutex unlocking (ID: {d})...\n", .{current_id});
                        defer queue_ptr.*.mutex.unlock();
                        const queue_len = queue_ptr.*.write_queue.items.len;
                        if (queue_len > 0) {
                            std.debug.print("EventLoop: Found {d} items in write queue (ID: {d}). Calling processWriteQueue...\n", .{queue_len, current_id});
                            self.processWriteQueue() catch |err| {
                                std.debug.print("Write queue processing error: {s}\n", .{@errorName(err)});
                            };
                            std.debug.print("Returned from processWriteQueue (ID: {d}).\n", .{current_id});
                        } else {
                            
                        }
                    } else {
                       std.debug.print("Could not lock write queue mutex (ID: {d}), skipping write processing.\n", .{current_id});
                    }

                } else {
                    std.debug.print("No connection queue found for ID: {d} in event loop write check.\n", .{current_id});
                }
                
            }




            {
                std.debug.print("DEBUG : Start 2 Branket Scoop\n", .{});

                if (self.event_loop_force_quit.load(.seq_cst)) {
                    std.debug.print("Event loop force quit signal received (before read)\n", .{});
                    self.event_loop_terminated.store(true, .seq_cst);
                    return;
                }


                std.debug.print("DEBUG : Mutex Before 2 Branket Scoop\n", .{});

                self.event_loop_is_safe_to_terminate.store(false, .seq_cst);

                std.debug.print("DEBUG : Mutex After 2 Branket Scoop\n", .{});


                std.debug.print("DEBUG : Before Loop readTimeout\n", .{});
                
                std.debug.print("DEBUG : After Loop readTimeout\n", .{});

                while (true) {
                    const message = self.getNextMessage() catch |err| {
                        std.debug.print("Queue error: {s}\n", .{@errorName(err)});
                        break;
                    };

                    if (message) |m| {
                        self.handleWebSocketMessage(allocator, m) catch |err| {
                             std.debug.print("EventLoop: Error handling message: {s}\n", .{@errorName(err)});
                             // Free message data if handleWebSocketMessage didn't
                             allocator.free(m.data);
                        };
                    } else {
                    if (self.event_loop_force_quit.load(.seq_cst)) {
                        self.event_loop_terminated.store(true, .seq_cst);
                        return;
                    }
                    break;
                    }
                }    

                std.debug.print("DEBUG : After Loop getNextMessage\n", .{});
                

                

                if (self.websocket.socket == null) {
                    std.debug.print("WebSocket socket became null during event loop\n", .{});
                    self.event_loop_terminated.store(true, .seq_cst);
                    return;
                }

            }
            
            std.debug.print("Event Loop Iteration End (ID: {d}), sleeping...\n", .{self.current_thread_version});
            std.time.sleep(50 * std.time.ns_per_ms);
        }

        self.event_loop_terminated.store(true, .seq_cst);
        std.debug.print("Event loop terminated normally\n", .{});
    }

    // Event loop thread function wrapper
    fn eventLoopThreadFnWrapper(ctx: *EventLoopContext) void {
    
        runEventLoop(ctx) catch |err| {
            std.debug.print("Error in event loop (v{d}): {s}\n", .{ctx.initial_connection_version, @errorName(err)});
            ctx.browser.event_loop_terminated.store(true, .seq_cst);
        };
    }

    // Start the event loop in a new thread
    pub fn startEventLoop(self: *Self, allocator: std.mem.Allocator) !void {
         const initial_version = self.connection_version.load(.seq_cst);
       
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
            .initial_connection_version = initial_version,
        };

        self.event_loop_thread = try std.Thread.spawn(.{}, eventLoopThreadFnWrapper, .{ctx});
    }

    /// Evaluate JavaScript code in the browser context
    pub fn evaluateJS(self: *Self, allocator: std.mem.Allocator,expression: []const u8,settings: EvaluateJSSettings) ![]const u8 {
       if (!self.websocket.is_connected) return error.NotConnected;

        if (self.websocket.socket == null) {
            return error.WebSocketDisconnected;
        }

        self.paused_for_eval.store(true, .seq_cst);
        defer self.paused_for_eval.store(false, .seq_cst);

        std.time.sleep(50 * std.time.ns_per_ms);
        

        if (self.websocket.socket == null) {
            return error.WebSocketDisconnected;
        }

        const message_id = self.next_message_id;
        self.next_message_id += 1;

        const message = try std.fmt.allocPrint(
            allocator, 
            "{{\"id\":{d},\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":\"{s}\"}}}}", 
            .{message_id, expression}
        );
        defer allocator.free(message);

        self.nonBlockingWrite(self.websocket.allocator, message) catch |err| {
            std.debug.print("Error writing to WebSocket: {s}\n", .{@errorName(err)});
            return err;
        };

        if (!settings.wait_for_response) {
            std.debug.print("evaluateJS: No wait for response, returning immediately\n", .{});
            return "";
        }

        const start_time = std.time.milliTimestamp();
        const timeout_ms = settings.wait_for_timeout;
    
        while (std.time.milliTimestamp() - start_time < timeout_ms) {
           while (true) {
                const response_opt = self.getNextMessage() catch |err| {
                    std.debug.print("Error getting next message: {s}\n", .{@errorName(err)});
                    break;
                };
               

                if (response_opt == null) {
                    std.debug.print("No message received, continuing...\n", .{});
                    break;
                }

                const response = response_opt.?;

                 if (response.data.len == 0) {
                    std.debug.print("Received empty message data in evaluateJS\n", .{});
                    continue;
                }

                var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.data, .{}) catch |parse_err| {
                    std.debug.print("JSON parse error in evaluateJS: {s}\nData: {s}\n", .{@errorName(parse_err), response.data});
                    continue;
                };
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
                        continue;
                    }
                }
           }
        std.time.sleep(settings.wait_for_interval * std.time.ns_per_ms);
    }
        return error.Timeout;
    }

    /// Inject a quit handler into the browser context
    pub fn injectQuitHandler(self: *Self, allocator: std.mem.Allocator) !void {
        const js_code = 
            \\window.__ZIG_QUIT = function() {
            \\  window.chrome.webSocketDebuggerSend({
            \\    customEvent: 'quit'
            \\  });
            \\};
            \\console.log('Quit handler injected. Call window.__ZIG_QUIT() to exit');
        ;
    
        _ = try self.evaluateJS(allocator, js_code,.{});
    }

    /// Inject a quit handler without locking the WebSocket connection
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

    pub fn nonBlockingWrite(self: *Self,allocator: std.mem.Allocator, message: []const u8) !void {

        const current_id = self.websocket.connection_id;
         self.connection_queues_mutex.lock();
        var queue_entry = self.connection_queues.getOrPut(current_id) catch |err| {
            std.debug.print("Error getting or putting connection queue: {s}\n", .{@errorName(err)});
            self.connection_queues_mutex.unlock();
            return err;
        };
        if (!queue_entry.found_existing) {
                std.debug.print("Creating new queue for connection ID: {d}\n", .{current_id});
                queue_entry.value_ptr.* = ConnectionQueue{
                    .write_queue = std.ArrayList(*WriteQueueItem).init(allocator),
                    .read_queue = std.ArrayList(*ReadQueueItem).init(allocator),
                    .mutex = std.Thread.Mutex{},
                };
        }    
        self.connection_queues_mutex.unlock();

        const queue_item = try allocator.create(WriteQueueItem);
        queue_item.* = WriteQueueItem{
            .data = try allocator.dupe(u8, message),
            .offset = 0,
            .allocator = allocator,
            };

        queue_entry.value_ptr.mutex.lock();
        defer queue_entry.value_ptr.mutex.unlock();
    
        try queue_entry.value_ptr.write_queue.append(queue_item);
        std.debug.print("DEBUG: Message queued, new length: {d}\n", 
        .{queue_entry.value_ptr.write_queue.items.len});
        
    }

    fn processWriteQueue(self: *Self) !void {
        const current_id = self.websocket.connection_id;
        std.debug.print("DEBUG: Processing queue for connection ID: {d}\n", .{current_id});
        if (self.connection_queues.getPtr(current_id)) |queue_ptr| {    

        if (queue_ptr.*.write_queue.items.len == 0) {
            std.debug.print("Queue is empty\n", .{});
            return;
        }

        if (self.websocket.socket == null or !self.websocket.is_connected) {
             std.debug.print("WebSocket not ready for writing in processWriteQueue (ID: {d})\n", .{current_id});
             return;
        }
        
        const i: usize = 0;
        while (i < queue_ptr.*.write_queue.items.len) {
            const item = queue_ptr.*.write_queue.items[i];
            
            std.debug.print("Sending message: {s}\n", .{item.data});
            
            self.websocket.socket.?.write(item.data) catch |err| {
                if (err == error.WouldBlock) {
                    std.debug.print("Write would block, deferring (ID: {d}, Index: {d})\n", .{current_id, i});
                    return;
                }
                std.debug.print("Write error: {s}\n", .{@errorName(err)});
                item.deinit();
                _ = queue_ptr.*.write_queue.orderedRemove(i);
                continue;
            };
            
            std.debug.print("Message sent successfully from queue (ID: {d}, Index: {d})\n", .{current_id, i});
            item.deinit();
            _ = queue_ptr.*.write_queue.orderedRemove(i);
        }
    } else {
        std.debug.print("No queue found for ID: {d}\n", .{current_id});
    }
    }

    pub fn nonBlockingRead(self: *Self, allocator: std.mem.Allocator) !void {
        const message = self.websocket.socket.?.read() catch |err| {
        if (err == error.WouldBlock or err == error.TimedOut) {
            return;
        }
        return err; 
        };
        if (message != null) {
            self.read_queue_mutex.lock();
            defer self.read_queue_mutex.unlock();
        
            const queue_item = try allocator.create(ReadQueueItem);
            queue_item.* = ReadQueueItem{
                .message = message,
                .complete = true,
                .allocator = allocator,
            };
        
            try self.read_queue.append(queue_item);
        }
    }
    // Get the next message from the read queue
    /// Returns null if the queue is empty
    pub fn getNextMessage(self: *Self) !?proto.Message {
         const current_id = self.websocket.connection_id;

        self.connection_queues_mutex.lock();
        const maybe_queue_ptr = self.connection_queues.getPtr(current_id);
        self.connection_queues_mutex.unlock();

        if (maybe_queue_ptr) |queue_ptr| {

            queue_ptr.mutex.lock();
            defer queue_ptr.mutex.unlock();

            if (queue_ptr.read_queue.items.len == 0) {
                return null;
            }
            if (queue_ptr.read_queue.pop()) |item_ptr| {
              
                 defer self.websocket.allocator.destroy(item_ptr); 
                
                 const message_to_return = item_ptr.message;
                 item_ptr.message = null; 

                 return message_to_return;

            } else {
                 return null;
            }

        } else {
            std.debug.print("getNextMessage: No read queue found for connection ID: {d}\n", .{current_id});
            return null;
        }
    }

    fn handleWebSocketMessage(self: *Self, allocator: std.mem.Allocator, message: proto.Message) !void {

        defer allocator.free(message.data);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, message.data, .{}) catch |err| {
             std.debug.print("JSON parse error: {s}\nData: {s}\n", .{@errorName(err), message.data});
             return err; 
        };
        defer parsed.deinit();

    
        if (parsed.value.object.get("method")) |method| {
            if (std.mem.eql(u8, method.string, "Page.loadEventFired") or
                std.mem.eql(u8, method.string, "Runtime.consoleAPICalled")) {
            
                try self.dispatchEvent(.OnMessage, message.data);
            }
            
        }

      
        if (parsed.value.object.get("customEvent")) |custom_event| {
            if (std.mem.eql(u8, custom_event.string, "quit")) {
                std.debug.print("Quit event received via WebSocket\n", .{});
                
                try self.dispatchEvent(.OnQuit, message.data);
               
                self.should_quit = true;
            }
          
        }

        // Handle responses to commands (identified by "id") if necessary
        if (parsed.value.object.get("id")) |id_val| {
            // This is a response to a command sent with an ID
            // You might want to correlate this ID with pending requests
            // and notify waiting code, potentially using another queue or map.
            _ = id_val; // Placeholder
        }
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

    pub fn getDebuggerUrl(allocator: std.mem.Allocator, port: u16) ![]const u8 {
        var client = std.http.Client{
            .allocator = allocator
        };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/json", .{port});
        defer allocator.free(url);
        const uri = try std.Uri.parse(url);

        var buffer: [32 * 1024]u8 = undefined;
        var response = try client.open(.GET, uri, .{
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

        var body_buffer = std.ArrayList(u8).init(allocator);
        defer body_buffer.deinit();

        try response.reader().readAllArrayList(&body_buffer, 32 * 1024);

        
        std.debug.print("Debug: received JSON: {s}\n", .{body_buffer.items});

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_buffer.items, .{});
        defer parsed.deinit();

        std.debug.print("Debug: JSON array length: {d}\n", .{parsed.value.array.items.len});

        var normal_tab_url: ?[]const u8 = null;
        var devtools_url: ?[]const u8 = null;

        if (parsed.value.array.items.len > 0) {
            for (parsed.value.array.items, 0..) |item, i| {
                std.debug.print("Debug: Checking item {d}\n", .{i});

                if (item.object.get("type")) |type_value| {
                    if (std.mem.eql(u8, type_value.string, "page")) {
                        if (item.object.get("url")) |url_value| {
                            if (std.mem.eql(u8, url_value.string, "chrome://newtab/")) {
                                if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
                                    std.debug.print("Debug: Found newtab page: {s}\n", .{ws_url.string});
                                    normal_tab_url = ws_url.string;
                                }
                            } else if (std.mem.startsWith(u8, url_value.string, "devtools://")) {
                                if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
                                    std.debug.print("Debug: Found DevTools page: {s}\n", .{ws_url.string});
                                    devtools_url = ws_url.string;
                                }
                            }
                        }

                        if (normal_tab_url) |normal_url| {
                            std.debug.print("Debug: Using normal tab URL: {s}\n", .{normal_url});
                            return allocator.dupe(u8, normal_url);
                        }

                        if (devtools_url == null) {
                            if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
                                devtools_url = ws_url.string;
                            }
                        }
                    }
                }
            }

            if (devtools_url) |dev_url| {
                std.debug.print("Debug: Using DevTools tab as fallback\n", .{});
                return allocator.dupe(u8, dev_url);
            }
        }

        std.debug.print("Debug: No suitable debugger URL found\n", .{});
        return error.NoDebuggerUrlFound;
    }

    pub fn getCurrentTabInfo(self: *Self, allocator: std.mem.Allocator) !void {
        if (!self.websocket.is_connected) return error.NotConnected;

        if (self.websocket.socket == null) {
            return error.WebSocketDisconnected;
        }

        self.websocket_mutex.lock();
        defer self.websocket_mutex.unlock();

        if (self.websocket.socket == null) {
            return error.WebSocketDisconnected;
        }

        const message_id = self.next_message_id;
        self.next_message_id += 1;
        
    const message = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"method\":\"Target.getTargets\"}}",
            .{message_id}
        );
        defer allocator.free(message);

        try self.websocket.socket.?.write(message);

        const start_time = std.time.milliTimestamp();
        const timeout_ms = 5000;

        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            if (try self.websocket.socket.?.read()) |response| {
                std.debug.print("Tab info response: {s}\n", .{response.data});
                return;
            }
            std.time.sleep(100 * std.time.ns_per_ms);
        }

        return error.Timeout;
    }

    pub fn connectToActiveTab(self: *Self, allocator: std.mem.Allocator) !void {
        
    const tab_url = try getActiveTabWebSocketUrl(allocator, self.settings.port.?);
        defer allocator.free(tab_url);

        std.debug.print("Connecting to active tab: {s}\n", .{tab_url});
        
    if (self.websocket.socket) |*socket| {
            socket.deinit();
            self.is_connected = false;
        }
        
        self.websocket.url = tab_url;
        try self.websocket.connect();
        self.is_connected = true;
        _ = self.connection_version.fetchAdd(1, .seq_cst);
    }

    pub fn connectToSelectNormalTab(self: *Self, state: BrowserState, value: u16) !void {
        std.debug.print("Starting tab connection switch process...\n", .{});

         if (value >= state.webSocketDebuggerUrl_Normal.items.len) {
            std.debug.print("Invalid tab index: {d}, max: {d}\n", .{value, state.webSocketDebuggerUrl_Normal.items.len});
            return error.InvalidTabIndex;
        }

        if (self.is_switching_connection.load(.seq_cst)) {
            std.debug.print("Another connection switch already in progress - aborting\n", .{});
            return error.ConnectionSwitchAlreadyInProgress;
        }

        self.is_switching_connection.store(true, .seq_cst);
        errdefer self.is_switching_connection.store(false, .seq_cst);

        const url_copy = try self.websocket.allocator.dupe(u8, state.webSocketDebuggerUrl_Normal.items[value]);
        std.debug.print("Forcefully changing connection state...\n", .{});
        errdefer self.websocket.allocator.free(url_copy);

        var new_connection = try WebSocketConnection.init(
            url_copy,
            self.websocket.allocator,
            self.settings.port
        );
        new_connection.owns_url = true;

        std.debug.print("Attempting connection to new tab...\n", .{});
            new_connection.connect() catch |err| {
                std.debug.print("WebSocket handshake failed: {s}\n", .{@errorName(err)});
                self.is_switching_connection.store(false, .seq_cst);
             return err;
            };

        std.debug.print("Signaling event loop to terminate...\n", .{});
        const old_version = self.connection_version.load(.seq_cst);
        _ = self.connection_version.fetchAdd(1, .seq_cst); 

        std.debug.print("Waiting for old event loop thread (v{d}) to join...\n", .{old_version});
        if (self.event_loop_thread) |thread| {
            thread.join(); 
            std.debug.print("Old event loop thread (v{d}) joined.\n", .{old_version});
            self.event_loop_thread = null; 
        } else {
            std.debug.print("No active event loop thread found to join during tab switch.\n", .{});
        }

        self.event_loop_terminated.store(false, .seq_cst);
        self.event_loop_force_quit.store(false, .seq_cst);

         std.debug.print("Attempting to lock connection_queues_mutex for tab switch...\n", .{});
        self.connection_queues_mutex.lock();
        std.debug.print("Locked connection_queues_mutex for tab switch.\n", .{});
        errdefer {
            std.debug.print("Unlocking connection_queues_mutex due to error in tab switch.\n", .{});
            self.connection_queues_mutex.unlock();
        }

        const queue_entry = try self.connection_queues.getOrPut(new_connection.connection_id);
        if (!queue_entry.found_existing) {

            queue_entry.value_ptr.* = ConnectionQueue{
                .write_queue = std.ArrayList(*WriteQueueItem).init(self.websocket.allocator),
                .read_queue = std.ArrayList(*ReadQueueItem).init(self.websocket.allocator),
                .mutex = std.Thread.Mutex{},
            };
             std.debug.print("Created new queue for connection ID: {d}\n", .{new_connection.connection_id});
        }

        std.debug.print("Unlocking connection_queues_mutex after getOrPut in tab switch.\n", .{});
        self.connection_queues_mutex.unlock();

        std.time.sleep(300 * std.time.ns_per_ms);
        {
            self.websocket_mutex.lock();
            defer self.websocket_mutex.unlock();

            self.websocket.deinit();
            self.websocket = new_connection;
            self.is_connected = true;
        }

        std.debug.print("Connection state updated without using mutex\n", .{});
        std.debug.print("OLD Resource Released\n",.{});
        std.debug.print("New Event Loop SetUp\n", .{});
       
        self.startEventLoop(self.websocket.allocator) catch |err| {
            self.websocket_mutex.lock();
            self.websocket.deinit();
            self.is_connected = false;
            self.websocket_mutex.unlock();
            self.is_switching_connection.store(false, .seq_cst);
            return err;
        };

        std.debug.print("Tab connection switch completed successfully\n", .{});
        self.is_switching_connection.store(false, .seq_cst);
    }

    fn checkChromeProcessAlive(allocator: std.mem.Allocator, port: u16) !bool {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/json/version", .{port});
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);

        var buffer: [8 * 1024]u8 = undefined;
        var response = client.open(.GET, uri, .{
            .server_header_buffer = &buffer,
        }) catch |err| {
            if (err == error.ConnectionRefused) {
                return false;
        }
            return err; 
    };

        defer response.deinit();

        response.send() catch |err| {
            std.debug.print("HTTP REQUEST SEND ERROR: {s}\n", .{@errorName(err)});
            return false;
        };
        response.wait() catch |err| {
            std.debug.print("HTTP REQUEST WAIT ERROR: {s}\n", .{@errorName(err)});
            return false;
        };
        response.finish() catch |err| {
            std.debug.print("HTTP REQUEST FINISH ERROR: {s}\n", .{@errorName(err)});
            return false;
        };

        return response.response.status == .ok;
    }

    pub fn getTabInfo(allocator: std.mem.Allocator, port: u16,browser: *ChromiumBrowser) !void {

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

        var found_debugger_url = false;

        if (parsed.value.array.items.len > 0){

            for (parsed.value.array.items, 0..) |item, i| {
                browser.state.tab.append(i) catch |err| {
                    std.debug.print("Error appending tab: {s}\n", .{@errorName(err)});
                    return err;
                };

                if (item.object.get("type")) |type_value| {
                    if (std.mem.eql(u8, type_value.string, "page")) {
                        if (item.object.get("url")) |url_value| {
                            if (std.mem.eql(u8, url_value.string, "chrome://newtab/")) {
                                if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
                                    std.debug.print("Debug: Found newtab page: {s}\n", .{ws_url.string});
                                    const duped_url = try allocator.dupe(u8, ws_url.string);
                                    errdefer allocator.free(duped_url);

                                    try browser.state.webSocketDebuggerUrl_Normal.append(duped_url);
                                    found_debugger_url = true;
                                }
                            } else if (std.mem.startsWith(u8, url_value.string, "devtools://")) {
                                if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
                                    std.debug.print("Debug: Found DevTools page: {s}\n", .{ws_url.string});
                                    const duped_url = try allocator.dupe(u8, ws_url.string);
                                    errdefer allocator.free(duped_url);

                                    try browser.state.webSocketDebuggerUrl_DevTools.append(duped_url);
                                    found_debugger_url = true;
                                }
                            }
                        }
                    }
                }
                if (item.object.get("title")) |title_value| {
                    const duped_title = try allocator.dupe(u8, title_value.string);
                    errdefer allocator.free(duped_title);

                    try browser.state.title.append(duped_title);
                }

                if (item.object.get("url")) |url_value| {
                    const duped_url = try allocator.dupe(u8, url_value.string);
                    errdefer allocator.free(duped_url);

                    try browser.state.url.append(duped_url);
                }

                if (item.object.get("id")) |id_value| {
                    const duped_id = try allocator.dupe(u8, id_value.string);
                    errdefer allocator.free(duped_id);

                    try browser.state.id.append(duped_id);
                }
            }
        }

        if (found_debugger_url) {
            return;
        } else {
            return error.NoDebuggerUrlFound;
        }
    }

    fn getActiveTabWebSocketUrl(allocator: std.mem.Allocator, port: u16) ![]const u8 {
        var client = std.http.Client{
            .allocator = allocator
        };
        defer client.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/json", .{port});
        defer allocator.free(url);
        const uri = try std.Uri.parse(url);

        var buffer: [32 * 1024]u8 = undefined;
        var response = try client.open(.GET, uri, .{
            .server_header_buffer = &buffer,
        });
        defer response.deinit();
        try response.send();
        try response.wait();
        try response.finish();

        var body_buffer = std.ArrayList(u8).init(allocator);
        defer body_buffer.deinit();

        try response.reader().readAllArrayList(&body_buffer, 32 * 1024);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_buffer.items, .{});
        defer parsed.deinit();

        if (parsed.value.array.items.len > 0) {
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

        return error.NoActiveTabFound;
    }

    pub fn navigate(self: *Self, allocator: std.mem.Allocator, url: []const u8) !void {
        std.debug.print("Attempting to navigate to: {s}\n", .{url});
        
        if (self.should_quit) {
            std.debug.print("Cannot navigate: Browser is shutting down\n", .{});
            return error.BrowserShuttingDown;
        }
        
        if (self.is_switching_connection.load(.seq_cst)) {
            std.debug.print("Cannot navigate while connection switch is in progress\n", .{});
            return error.ConnectionSwitchInProgress;
        }
        
        if (!self.websocket.is_connected) {
            std.debug.print("Cannot navigate: WebSocket is not connected\n", .{});
            return error.NotConnected;
        }
        
        if (self.websocket.socket == null) {
            std.debug.print("Cannot navigate: WebSocket socket is null\n", .{});
            return error.WebSocketDisconnected;
        }
        
        std.time.sleep(50 * std.time.ns_per_ms);
        
        if (self.should_quit) {
            std.debug.print("Browser shutdown detected after acquiring mutex\n", .{});
            return error.BrowserShuttingDown;
        }
        
        if (self.websocket.socket == null) {
            std.debug.print("Socket became null after acquiring lock\n", .{});
            return error.WebSocketDisconnected;
        }
        
        if (!self.websocket.is_connected) {
            std.debug.print("WebSocket was disconnected after acquiring lock\n", .{});
            return error.NotConnected;
        }
        
        const current_version = self.connection_version.load(.seq_cst);
        
        const message_id = self.next_message_id;
        self.next_message_id += 1;
        
        const message = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"method\":\"Page.navigate\",\"params\":{{\"url\":\"{s}\"}}}}",
            .{message_id, url}
        );
        defer allocator.free(message);
        
        std.debug.print("Before nonBlockingWrite Function", .{});
    
        self.nonBlockingWrite(self.websocket.allocator, message) catch |err| {
            std.debug.print("Error during non-blocking write: {s}\n", .{@errorName(err)});
            return err;
        };
        
        if (current_version != self.connection_version.load(.seq_cst)) {
            std.debug.print("Connection version changed during navigation\n", .{});
            return error.ConnectionChanged;
        }
        
        self.dispatchEvent(.OnNavigate, url) catch |err| {
            std.debug.print("Failed to dispatch navigation event: {s}\n", .{@errorName(err)});
        };
        
        std.debug.print("Navigation command sent successfully to {s}\n", .{url});
        return;
    }

    pub fn mouseClick(self: *Self, allocator: std.mem.Allocator, x: f64, y: f64) !void {

        const message_id = self.next_message_id;
        self.next_message_id += 1;
        
        {
            const js_code = comptime  getJSExpressionTemplate(.MouseClickDown);
            const js_cmd = try std.fmt.allocPrint(
                allocator, 
                js_code, 
                .{message_id,x, y}
            );
            defer allocator.free(js_cmd);
            _ = try self.evaluateJS(allocator, js_cmd,.{
                .wait_for_response = false,
            });
        }

        {
            const js_code = comptime  getJSExpressionTemplate(.MouseClickUp);
            const js_cmd = try std.fmt.allocPrint(
                allocator, 
                js_code, 
                .{message_id, x, y}
            );
            defer allocator.free(js_cmd);
            _ = try self.evaluateJS(allocator, js_cmd,.{
                .wait_for_response = false,
            });
        }
    }

    pub fn typeText(self: *Self, allocator: std.mem.Allocator, text: []const u8) !void {
        const message_id = self.next_message_id;
        self.next_message_id += 1;

        const js_code = comptime  getJSExpressionTemplate(.TypeText);
        const js_cmd = try std.fmt.allocPrint(
            allocator, 
            js_code, 
            .{message_id,text}
        );
        defer allocator.free(js_cmd);

        self.nonBlockingWrite(self.websocket.allocator, js_cmd) catch |err| {
            std.debug.print("Error during non-blocking write: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    pub fn clickElement(self: *Self, allocator: std.mem.Allocator, selector: []const u8) !void {
        const js_code = comptime getJSExpressionTemplate(.ClickElement);
        const js_cmd = try std.fmt.allocPrint(
            allocator, 
            js_code, 
            .{selector}
        );
        defer allocator.free(js_cmd);

        _ = try self.evaluateJS(allocator, js_cmd,.{
            .wait_for_response = false,
        });
    }

};

pub const BrowserSettings = struct {
    url: []const u8,
    session_id: []const u8,
    port: ?u16 = 9222,
    local_mode: LocalBrowserMode,
    headless: ?bool = true,
    auto_open_devtools: ?bool = false,
};

pub const EvaluateJSSettings = struct {
    wait_for_response: bool = true,
    wait_for_timeout: u32 = 5000,
    wait_for_interval: u32 = 100,
};

pub const JSType = enum {
    QuitHandler,
    ClickElement,
    TypeText,
    MouseClickDown,
    MouseClickUp,
    Navigate,
};

pub fn getJSExpressionTemplate(js_code: JSType) []const u8 {
    return switch (js_code) {
        .QuitHandler => "window.close();",
        .ClickElement => "document.querySelector(\"{s}\").click();",
        .TypeText => "{{\"id\":{d},\"method\":\"Input.insertText\",\"params\":{{\"text\":\"{s}\"}}}}",
        .MouseClickDown => "{{\"id\":{d},\"method\":\"Input.dispatchMouseEvent\",\"params\":{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}}}",
        .MouseClickUp => "{{\"id\":{d},\"method\":\"Input.dispatchMouseEvent\",\"params\":{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}}}", 
        .Navigate => "window.location.href = \"{s}\";",
    };
}

pub const BrowserState = struct {
    tab: std.ArrayList(usize),
    title: std.ArrayList([]const u8),
    url:std.ArrayList([]const u8),
    webSocketDebuggerUrl_Normal: std.ArrayList([]const u8),
    webSocketDebuggerUrl_DevTools: std.ArrayList([]const u8),
    id: std.ArrayList([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .tab = std.ArrayList(usize).init(allocator),
            .title = std.ArrayList([]const u8).init(allocator),
            .url = std.ArrayList([]const u8).init(allocator),
            .webSocketDebuggerUrl_Normal = std.ArrayList([]const u8).init(allocator),
            .webSocketDebuggerUrl_DevTools = std.ArrayList([]const u8).init(allocator),
            .id = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {

        for (self.title.items) |item| {
            self.title.allocator.free(item);
        }
        for (self.url.items) |item| {
            self.url.allocator.free(item);
        }
        for (self.webSocketDebuggerUrl_Normal.items) |item| {
            self.webSocketDebuggerUrl_Normal.allocator.free(item);
        }
        for (self.webSocketDebuggerUrl_DevTools.items) |item| {
            self.webSocketDebuggerUrl_DevTools.allocator.free(item);
        }
        for (self.id.items) |item| {
            self.id.allocator.free(item);
        }
        
        self.tab.deinit();
        self.title.deinit();
        self.url.deinit();
        self.webSocketDebuggerUrl_Normal.deinit();
        self.webSocketDebuggerUrl_DevTools.deinit();
        self.id.deinit();
    }
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
    OnNavigate,
    OnQuit,
};

pub const LocalBrowserMode = enum {
    Download,
    Embedded,
};

const Handler = struct {
    client: *ws.Client,
    
    fn init(allocator: std.mem.Allocator,browser: ChromiumBrowser) !void {
        var client = try ws.Client.init(allocator, .{
            .port = browser.settings.port,
            .host = "localhost",
        });
        defer client.deinit();
    }
};

pub const ConnectionQueue = struct {
    write_queue: std.ArrayList(*WriteQueueItem),
    read_queue: std.ArrayList(*ReadQueueItem),
    mutex: std.Thread.Mutex,
};

pub const WriteQueueItem = struct {
    data: []u8,
    offset: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WriteQueueItem) void {
        self.allocator.free(self.data);
    }
};

pub const ReadQueueItem = struct {
    message: ? proto.Message,
    complete: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReadQueueItem) void {
        if (self.message) |*msg| {
            self.allocator.free(msg.data);
        } 
    }
};

var global_websocket_connection_counter: u64 = 0;

pub const WebSocketConnection = struct {
    url: []const u8,
    socket: ?ws.Client = null,
    
    allocator: std.mem.Allocator,
    port: u16 = 9222,
    owns_url: bool = false,

    is_connected: bool,
    connection_id: u64 = 0,

    const Self = @This();

    pub fn init(url: []const u8, gpa: std.mem.Allocator,port: ?u16) !Self {
        const id = @atomicRmw(u64, &global_websocket_connection_counter, .Add, 1, .seq_cst);
        std.debug.print("Creating new WebSocketConnection (ID: {d}) for URL: {s}\n", .{id, url});
        return Self{ 
            .url = url,
            .allocator = gpa,
            .is_connected = false,
            .port = port orelse 9222,
            .owns_url = false,
            .connection_id = id,
        };
    }

    pub fn initWithDupedUrl(url: []const u8, gpa: std.mem.Allocator, port: ?u16) !Self {
        const url_copy = try gpa.dupe(u8, url);
        const id = @atomicRmw(u64, &global_websocket_connection_counter, .Add, 1, .seq_cst);
        std.debug.print("Creating new WebSocketConnection (ID: {d}) with duped URL: {s}\n", .{id, url});
        return Self{
            .url = url_copy,
            .allocator = gpa,
            .is_connected = false,
            .port = port orelse 9222,
            .owns_url = true,  
            .connection_id = id,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.print("Deinitializing WebSocketConnection (ID: {d})\n", .{self.connection_id});
        
        if (self.socket) |*socket| {
            std.debug.print("Closing WebSocket (ID: {d})\n", .{self.connection_id});
            socket.deinit();
            self.socket = null;
        }
        
        if (self.owns_url) {
            std.debug.print("Freeing owned URL for WebSocketConnection (ID: {d})\n", .{self.connection_id});
            self.allocator.free(self.url);
            self.owns_url = false;
        }
        
        self.is_connected = false;
    }

    pub fn connect(self: *Self) !void {
        if (self.is_connected) {
            std.debug.print("WebSocketConnection (ID: {d}) is already connected\n", .{self.connection_id});
            return;
        }

        std.debug.print("Starting WebSocket connection (ID: {d}) to {s}\n", .{self.connection_id, self.url});

        if (self.socket) |*socket| {
            std.debug.print("Cleaning up existing socket before new connection (ID: {d})\n", .{self.connection_id});
            socket.deinit();
            self.socket = null;
        }

        self.socket = ws.Client.init(self.allocator, .{
            .port = self.port,
            .host = "localhost"
        }) catch |err| {
            std.debug.print("WebSocket client init failed (ID: {d}): {s}\n", .{self.connection_id, @errorName(err)});
            return err;
        };

        var path: []const u8 = "/";

        if (std.mem.indexOf(u8, self.url, "://")) |pos| {
            const after_protocol = self.url[pos + 3..];
            if (std.mem.indexOf(u8, after_protocol, "/")) |slash_pos| {
                if (slash_pos < after_protocol.len) {
                    path = after_protocol[slash_pos..];
                    std.debug.print("WebSocket path (ID: {d}): {s}\n", .{self.connection_id, path});
                }
            }
        }

        std.debug.print("WebSocket (ID: {d}) connecting to path: {s}\n", .{self.connection_id, path});

        const headers = try std.fmt.allocPrint(self.allocator, "Host: localhost:{d}", .{self.port});
        defer self.allocator.free(headers);
        
        std.debug.print("Attempting WebSocket handshake (ID: {d}) with timeout 2000ms...\n", .{self.connection_id});
        
        self.socket.?.handshake(path, .{ 
            .timeout_ms = 2000,
            .headers = headers
        }) catch |err| {
            std.debug.print("WebSocket handshake failed (ID: {d}): {s}\n", .{self.connection_id, @errorName(err)});
            self.socket.?.deinit();
            self.socket = null;
            return err;
        };

        std.debug.print("WebSocket connected successfully! (ID: {d})\n", .{self.connection_id});
        self.is_connected = true;
    }
};

pub fn onJSResult(
    _ : EventListener,
    _: *ChromiumBrowser,
    message: []const u8,
) void {
    std.debug.print("JS Result: {s}\n", .{message});
}

pub const BrowserDevToolsUrl = struct {
  pub  const chromium_url : []const u8 = "ws://localhost:9222/devtools/browser";
};
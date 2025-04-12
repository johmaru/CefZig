const std = @import("std");
const cef = @import("cef.zig");
const builtin = @import("builtin");

pub fn main() !void {
    // Set the console output to UTF-8
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }

    const allocator = std.heap.page_allocator;

    // this code is auto download the chromium browser
    
    //var downloader = try chromium_downloader.ChromiumDownloader.init(allocator);
   //try downloader.download();
   // try downloader.unzip(.{.replace = true});

     //const ziptest = try chromium_downloader.lookup_zip(allocator);
    //defer allocator.free(ziptest);

     //for (ziptest) |zippath| {
     //    std.debug.print("Found zip file: {s}\n", .{zippath});
   // }


    // need to run the chromium downloader
    // port is can any port
    // url is the url of the chromium browser
    var browser = try cef.ChromiumBrowser.init(allocator, .{
        .local_mode = cef.LocalBrowserMode.Download,
        .port = 9222,
        .url = cef.BrowserDevToolsUrl.chromium_url,
        .session_id = "123456",
        .headless = false,
        .auto_open_devtools = true,
    });

    // run the browser
    browser.run() catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        return err;
    };

    defer browser.close() catch |err| {
        std.debug.print("Error closing browser: {s}\n", .{@errorName(err)});
    };

    std.time.sleep(2 * std.time.ns_per_s);

    std.debug.print("Now Test Run After\n", .{});

    // add an event listener for the OnJSEval event
    try browser.addEventListener(cef.EventType.OnJSEval, cef.onJSResult);

    std.debug.print("Add EventListner\n", .{});

    // evaluate some js
   // const result = try browser.evaluateJS(allocator, "document.title");
  //  defer allocator.free(result);
    
   // std.debug.print("Evaluated JS: {s}\n", .{result});

    browser.connectToSelectNormalTab(browser.state, 0) catch |err| {
        std.debug.print("Error connecting to tab: {s}\n", .{@errorName(err)});
        return err;
    };
    
    std.debug.print("Connected to tab\n", .{});

    browser.navigate(browser.websocket.allocator, "https://www.google.co.jp/") catch |err| {
    std.debug.print("Error navigating: {s}\n", .{@errorName(err)});
    };

    std.debug.print("Navigated to Google\n", .{});

    // dispatch the event
   // try browser.dispatchEvent(.OnJSEval, result);

    var timeout:u64 = 0;
    while (timeout < 5) : (timeout += 1) {
        std.debug.print("Waiting for 1 second...\n", .{});
        std.time.sleep(1 * std.time.ns_per_s);
    }

    
    std.debug.print("Browser closed\n", .{});
    std.debug.print("Test run complete\n", .{});

}
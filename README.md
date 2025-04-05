# CEFZIG

## How to use

Now this library features has 
- Navigate a Url
- Move Mouse Cursor on Chromium
- Click Javascript Element
- Click on Mouse Cursor Element
- TypeText
Anyway here the test code

```zig
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

```
const std = @import("std");
const builtin = @import("builtin");


pub const ChromiumDownloader = struct {

    allocator: std.mem.Allocator,
    file_name: [] u8,

    const winUrl = "https://download-chromium.appspot.com/dl/Win_x64?type=snapshots";

    const Self = @This();

    /// Must be called before using the struct
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .file_name = "",
        };
    }
    /// if you not required to use the struct, you can call this function to free the memory
    pub fn deinit(self: *Self) void {
        if (self.file_name != null) {
            self.allocator.free(self.file_name);
        }
    }

    /// Download the chromium zip file from the given URL
   pub fn download(self: *Self) !void {
        switch (builtin.os.tag) {
            .windows => {
                const uri = try std.Uri.parse(winUrl);

                var client = std.http.Client{ .allocator = self.allocator};
                defer client.deinit();

                var fmt_allocator = std.heap.page_allocator;

                const file_name = try std.fmt.allocPrint(fmt_allocator,"chromium-{d}.zip", .{std.time.milliTimestamp()});
                defer fmt_allocator.free(file_name);

                self.file_name = try self.allocator.dupe(u8, file_name);

                const file = try std.fs.cwd().createFile(file_name,.{});
                defer file.close();

                var buffer: [32 * 1024]u8 = undefined;
                var request = try client.open(.GET,uri, .{
                    .server_header_buffer = &buffer,
                    .redirect_behavior = @enumFromInt(10),
                });
                defer request.deinit();

                request.send() catch |err| {
                    std.log.err("HTTP REQUEST SEND ERROR: {s}", .{@errorName(err)});
                    return err;
                };

                request.wait() catch |err| {
                    std.log.err("HTTP REQUEST WAIT ERROR: {s}", .{@errorName(err)});
                    return err;
                };

                request.finish() catch |err| {
                    std.log.err("HTTP REQUEST FINISH ERROR: {s}", .{@errorName(err)});
                    return err;
                };

                if (request.response.status != std.http.Status.ok) {
                    std.log.err("Server has returned status code {d}", .{request.response.status});
                    return error.UnexpectedStatusCode;
                }

                while (true) {
                    const byte_read = request.reader().read(&buffer) catch |err| {
                    std.log.err("Data Read Error: {s}", .{@errorName(err)});
                    return err;
                };
                if (byte_read == 0) break;
                    file.writeAll(buffer[0..byte_read]) catch |err| {
                    std.log.err("File Write Error: {s}", .{@errorName(err)});
                    return err;
                };
                }
            },
            .linux => {
                error.LinuxCurrentlyNotSupported;
            },
            else => {
                error.UnsupportedOperatingSystem;
            },
        }
    }

    /// Optional
    pub const UnZipOptions = struct {
        replace: ?bool = true,
    };

    /// Unzip the downloaded file
    /// If the directory already exists, it will be deleted if `replace` is set to true
    /// If `replace` is set to false, it will return an error
    /// If the directory does not exist, it will be created
   pub fn unzip(self: *Self,options :UnZipOptions) !void {
        var zip_file = try std.fs.cwd().openFile(self.file_name, .{});
        defer zip_file.close();

        var seek = zip_file.seekableStream();

       std.fs.cwd().makeDir("chromium") catch |err| {
        if (err != error.PathAlreadyExists ) {
            std.log.err("Directory Creation Error: {s}", .{@errorName(err)});
            return err;
        }
        
        if (err == error.PathAlreadyExists) {
            if (options.replace == true){
                std.fs.cwd().deleteTree("chromium") catch |deleteerr| {
                    return deleteerr;
                };
                std.fs.cwd().makeDir("chromium") catch |continuemakeerror| {
                    return continuemakeerror;
                };
            } else {
                return err;
            }
        }

       };

        var stat_chromium = try std.fs.cwd().openDir("chromium", .{});
        defer stat_chromium.close();


        var dest = try std.fs.cwd().openDir("chromium", .{});
        defer dest.close();

        var diagnostics = std.zip.Diagnostics{ .allocator = self.allocator };
        defer diagnostics.deinit();

        std.zip.extract(dest,&seek, .{ .allow_backslashes = true, .diagnostics = &diagnostics }) catch |err| {
            std.log.err("ZIP EXTRACT ERROR: {s}", .{@errorName(err)});
            return err;
        };

    }

    /// Remove the downloaded file
    pub fn remove(self: *Self) !void {
        std.fs.cwd().deleteFile(self.file_name) catch |err| {
            return err;
        };
    }
    /// Remove the downloaded file and the extracted directory
    /// If the directory does not exist, it will return an error
    pub fn remove_all(self: *Self) !void {

        std.fs.cwd().deleteFile(self.file_name) catch |err| {
            return err;
        };
        try std.fs.cwd().deleteTree("chromium");
    }
};

/// lookup the zip file in the current directory
/// If the zip file is not found, it will return an ZipFileNotFound error
/// If the zip file is found, it will return the name of the zip file
/// Memory will be allocated using the given allocator
pub fn lookup_zip(allocator: std.mem.Allocator) ![][]const u8 {

        var dir = try std.fs.cwd().openDir("", .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();

        var name_list = std.ArrayList([]const u8).init(allocator);

        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ".zip")) {
                    try name_list.append(try allocator.dupe(u8, entry.name));
                }
            }
        }

        if (name_list.items.len == 0) {
            return error.ZipFileNotFound;
        }

        return name_list.toOwnedSlice();
    }
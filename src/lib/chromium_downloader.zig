const std = @import("std");


pub const ChromiumDownloader = struct {

    allocator: std.mem.Allocator,

    const winUrl = "https://download-chromium.appspot.com/dl/Win_x64?type=snapshots";

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }

   pub fn download(self: *Self) !void {
        const uri = try std.Uri.parse(winUrl);

        var client = std.http.Client{ .allocator = self.allocator};
        defer client.deinit();

        const file = try std.fs.cwd().createFile("chromium.zip",.{});
        defer file.close();

        var buffer: [32 * 1024]u8 = undefined;
        var request = try client.open(.GET,uri, .{
            .server_header_buffer = &buffer,
            .redirect_behavior = @enumFromInt(10),
        });
        defer request.deinit();

        request.send() catch |err| {
            std.log.err("HTTPリクエスト送信エラー: {s}", .{@errorName(err)});
            return err;
        };

        request.wait() catch |err| {
            std.log.err("HTTPリクエスト待機エラー: {s}", .{@errorName(err)});
            return err;
        };

        request.finish() catch |err| {
            std.log.err("HTTPリクエスト完了エラー: {s}", .{@errorName(err)});
            return err;
        };

        if (request.response.status != std.http.Status.ok) {
            std.log.err("サーバーがステータスコード {d} を返しました", .{request.response.status});
            return error.UnexpectedStatusCode;
        }

        while (true) {
           const byte_read = request.reader().read(&buffer) catch |err| {
            std.log.err("データ読み取りエラー: {s}", .{@errorName(err)});
            return err;
        };
            if (byte_read == 0) break;
            file.writeAll(buffer[0..byte_read]) catch |err| {
                std.log.err("ファイル書き込みエラー: {s}", .{@errorName(err)});
                return err;
            };
        }
    }

   pub fn unzip(self: *Self) !void {
        var zip_file = try std.fs.cwd().openFile("chromium.zip", .{});
        defer zip_file.close();

        var seek = zip_file.seekableStream();

        std.fs.cwd().makeDir("chromium") catch |err| {
        if (err != error.PathAlreadyExists) return err;
        };

        var dest = try std.fs.cwd().openDir("chromium", .{});
        defer dest.close();

        var diagnostics = std.zip.Diagnostics{ .allocator = self.allocator };
        defer diagnostics.deinit();

        try std.zip.extract(dest,&seek, .{ .allow_backslashes = true, .diagnostics = &diagnostics });

    }

};
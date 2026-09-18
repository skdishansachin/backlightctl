const std = @import("std");

const version = "0.1.0";

const usage: []const u8 =
    \\backlightctl 0.1.0 - read, write, and watch display brightness via sysfs.
    \\
    \\Usage: backlightctl [options] [operation] [value]
    \\
    \\With no operation, show status:
    \\  Device 'intel_backlight': 240/1000 (24%)
    \\
    \\Operations:
    \\  get                 print current brightness.
    \\  max                 print maximum brightness.
    \\  set VALUE           set brightness (see Values).
    \\  monitor             print one line per brightness change, forever.
    \\  -l, --list          list devices.
    \\
    \\Options:
    \\  -d, --device DEV    use device DEV (default: the only device; error if many).
    \\  -h, --help          print this help.
    \\  -V, --version       print version and exit.
    \\
    \\Values (one rule: optional sign, number, optional percent):
    \\  500                 set to 500.
    \\  50%                 set to 50% of maximum (rounded half up).
    \\  +10                 add 10 to current.
    \\  -10                 subtract 10 from current (never below 1).
    \\  +10%                add 10% of maximum to current.
    \\  -10%                subtract 10% of maximum from current.
    \\  Results clamp to [1, max].
    \\
    \\Monitor lines look like:
    \\  intel_backlight,240,1000,24%
    \\  i.e. name,current,maximum,percent — first line is current state.
    \\
    \\Permissions:
    \\  Writing needs access to /sys/class/backlight. Either install
    \\  contrib/90-backlight.rules or run as root.
    \\
    \\Notes:
    \\  Inspired by brightnessctl, not compatible with it: exact device
    \\  names only, backlight class only, one value rule (no 50- form).
    \\
    \\Examples:
    \\  backlightctl                show status.
    \\  backlightctl set +5%        brightness keys: brighter.
    \\  backlightctl set 50%        half brightness.
    \\  backlightctl monitor        feed a status bar.
    \\
;

const Args = struct {
    operation: ?Operation = null,
    device: ?[]const u8 = null,
    list: bool = false,
    help: bool = false,
    version: bool = false,

    const Operation = enum { get, max };

    const ParseError = error{
        UnknownFlag,
        UnknownOperation,
        TooManyOperations,
        MissingValue,
        InvalidValue,
    };

    fn parse(argv: []const []const u8) ParseError!Args {
        var self: Args = .{};
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    self.help = true;
                } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                    self.version = true;
                } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                    if (self.operation != null) return error.TooManyOperations;
                    self.list = true;
                } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--device")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    if (argv[i].len == 0) return error.InvalidValue;
                    self.device = argv[i];
                } else if (std.mem.startsWith(u8, arg, "--device=")) {
                    const val = arg["--device=".len..];
                    if (val.len == 0) return error.InvalidValue;
                    self.device = val;
                } else if (std.mem.startsWith(u8, arg, "-d")) {
                    const val = arg[2..];
                    if (val.len == 0) return error.InvalidValue;
                    self.device = val;
                } else {
                    return error.UnknownFlag;
                }
            } else if (std.mem.eql(u8, arg, "get")) {
                if (self.operation != null or self.list) return error.TooManyOperations;
                self.operation = .get;
            } else if (std.mem.eql(u8, arg, "max")) {
                if (self.operation != null or self.list) return error.TooManyOperations;
                self.operation = .max;
            } else {
                return error.UnknownOperation;
            }
        }
        return self;
    }
};

const base_directory = "/sys/class/backlight";

fn list(io: std.Io, allocator: std.mem.Allocator) ![][]const u8 {
    var directory = try std.Io.Dir.openDirAbsolute(io, base_directory, .{ .iterate = true, .follow_symlinks = true });
    defer directory.close(io);
    return listIn(directory, io, base_directory, allocator);
}

fn listIn(directory: std.Io.Dir, io: std.Io, base_path: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_path, entry.name });
        const dir = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(dir);
        try out.append(allocator, dir);
    }
    return try out.toOwnedSlice(allocator);
}

fn name(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

fn readU32(path: []const u8, io: std.Io, file: []const u8) !u32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ path, file });

    var buf: [32]u8 = undefined;
    const data = try std.Io.Dir.cwd().readFile(io, file_path, &buf);
    return try std.fmt.parseInt(u32, std.mem.trim(u8, data, " \n\r\t"), 10);
}

fn current(path: []const u8, io: std.Io) !u32 {
    return readU32(path, io, "actual_brightness") catch |err| {
        if (err == error.FileNotFound) return readU32(path, io, "brightness");
        return err;
    };
}

fn percent(current_value: u32, max_value: u32) u8 {
    if (max_value == 0) return 0;
    return @intCast(@min(@as(u64, current_value) * 100 / max_value, 100));
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    const argv = try init.minimal.args.toSlice(allocator);
    const args = Args.parse(argv) catch fail("error: invalid arguments; try 'backlightctl --help'\n", .{});

    if (args.help) {
        try stdout.print("{s}\n", .{usage});
        try stdout.flush();
        return;
    }

    if (args.version) {
        try stdout.print("{s}\n", .{version});
        try stdout.flush();
        return;
    }

    if (args.list) {
        const paths = list(io, allocator) catch fail("error: cannot read backlight devices\n", .{});
        defer {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }

        var shown = false;
        for (paths) |p| {
            if (args.device) |wanted| {
                if (!std.mem.eql(u8, name(p), wanted)) continue;
            }
            const cur = current(p, io) catch fail("error: cannot read brightness for '{s}'\n", .{name(p)});
            const max = readU32(p, io, "max_brightness") catch fail("error: cannot read max brightness for '{s}'\n", .{name(p)});
            try stdout.print("Device '{s}': {d}/{d} ({d}%)\n", .{ name(p), cur, max, percent(cur, max) });
            shown = true;
        }

        if (!shown) {
            if (args.device) |wanted| fail("error: no such device '{s}'\n", .{wanted});
            fail("error: no backlight devices found\n", .{});
        }
        try stdout.flush();
        return;
    }

    const dir: []const u8 = blk: {
        const paths = list(io, allocator) catch fail("error: cannot read backlight devices\n", .{});
        defer allocator.free(paths);
        if (args.device) |wanted| {
            for (paths, 0..) |p, i| {
                if (!std.mem.eql(u8, name(p), wanted)) continue;
                for (paths, 0..) |other, j| {
                    if (j != i) allocator.free(other);
                }
                break :blk p;
            }
            for (paths) |p| allocator.free(p);
            fail("error: no such device '{s}'\n", .{wanted});
        }
        if (paths.len == 0) fail("error: no backlight devices found\n", .{});
        if (paths.len > 1) {
            for (paths) |p| allocator.free(p);
            fail("error: multiple backlight devices found, specify -d DEVICE (see `backlightctl -l`)\n", .{});
        }
        break :blk paths[0];
    };
    defer allocator.free(dir);
    const dev_name = name(dir);

    const cur = current(dir, io) catch fail("error: cannot read brightness for '{s}'\n", .{dev_name});
    const max = readU32(dir, io, "max_brightness") catch fail("error: cannot read max brightness for '{s}'\n", .{dev_name});

    const op = args.operation orelse {
        try stdout.print("Device '{s}': {d}/{d} ({d}%)\n", .{ dev_name, cur, max, percent(cur, max) });
        try stdout.flush();
        return;
    };

    switch (op) {
        .get => {
            try stdout.print("{d}\n", .{cur});
            try stdout.flush();
        },
        .max => {
            try stdout.print("{d}\n", .{max});
            try stdout.flush();
        },
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Args);
}

test "help and version flags" {
    try std.testing.expect((try Args.parse(&.{ "backlightctl", "-h" })).help);
    try std.testing.expect((try Args.parse(&.{ "backlightctl", "--help" })).help);
    try std.testing.expect((try Args.parse(&.{ "backlightctl", "-V" })).version);
    try std.testing.expect((try Args.parse(&.{ "backlightctl", "--version" })).version);
}

test "unknown flag and operation" {
    try std.testing.expectError(error.UnknownFlag, Args.parse(&.{ "backlightctl", "--frobnicate" }));
    try std.testing.expectError(error.UnknownOperation, Args.parse(&.{ "backlightctl", "frobnicate" }));
}

test "get operation" {
    try std.testing.expectEqual(Args.Operation.get, (try Args.parse(&.{ "backlightctl", "get" })).operation.?);
    try std.testing.expectEqual(@as(?Args.Operation, null), (try Args.parse(&.{"backlightctl"})).operation);
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "get", "get" }));
}

test "max operation" {
    try std.testing.expectEqual(Args.Operation.max, (try Args.parse(&.{ "backlightctl", "max" })).operation.?);
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "get", "max" }));
}

test "list flag" {
    try std.testing.expect((try Args.parse(&.{ "backlightctl", "-l" })).list);
    try std.testing.expect((try Args.parse(&.{ "backlightctl", "--list" })).list);
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "get", "-l" }));
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "-l", "get" }));
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "max", "--list" }));
}

test "no args defaults to status" {
    const args = try Args.parse(&.{"backlightctl"});
    try std.testing.expect(args.operation == null);
    try std.testing.expect(!args.list);
}

test "percent computes clamped percentage" {
    try std.testing.expectEqual(@as(u8, 10), percent(100, 1000));
    try std.testing.expectEqual(@as(u8, 24), percent(240, 1000));
    try std.testing.expectEqual(@as(u8, 100), percent(1000, 1000));
    try std.testing.expectEqual(@as(u8, 100), percent(2000, 1000));
    try std.testing.expectEqual(@as(u8, 0), percent(0, 0));
}

test "device flag forms" {
    const separate = try Args.parse(&.{ "backlightctl", "-d", "intel_backlight" });
    try std.testing.expectEqualStrings("intel_backlight", separate.device.?);
    const attached = try Args.parse(&.{ "backlightctl", "-dintel_backlight" });
    try std.testing.expectEqualStrings("intel_backlight", attached.device.?);
    const long_eq = try Args.parse(&.{ "backlightctl", "--device=intel_backlight" });
    try std.testing.expectEqualStrings("intel_backlight", long_eq.device.?);
    try std.testing.expectError(error.MissingValue, Args.parse(&.{ "backlightctl", "-d" }));
    try std.testing.expectError(error.InvalidValue, Args.parse(&.{ "backlightctl", "--device=" }));
}

fn makeFakeDevice(dir: *std.Io.Dir, io: std.Io, device_name: []const u8, brightness: []const u8, max_brightness: []const u8) !void {
    try dir.createDir(io, device_name, .default_dir);
    var sub = try dir.openDir(io, device_name, .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "brightness", .data = brightness });
    try sub.writeFile(io, .{ .sub_path = "actual_brightness", .data = brightness });
    try sub.writeFile(io, .{ .sub_path = "max_brightness", .data = max_brightness });
}

test "list finds fake devices" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFakeDevice(&tmp.dir, io, "intel_backlight", "100\n", "1000\n");
    try makeFakeDevice(&tmp.dir, io, "acpi_video0", "200\n", "1000\n");

    const paths = try listIn(tmp.dir, io, "/fake-sysfs", allocator);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);
}

test "read current and max from fake device" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFakeDevice(&tmp.dir, io, "intel_backlight", "100\n", "1000\n");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..base_len];

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/intel_backlight", .{base});

    try std.testing.expectEqual(@as(u32, 100), try current(dir, io));
    try std.testing.expectEqual(@as(u32, 1000), try readU32(dir, io, "max_brightness"));
    try std.testing.expectEqualStrings("intel_backlight", name(dir));
    try std.testing.expectEqual(@as(u8, 10), percent(100, 1000));
}

test "current falls back to brightness file" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "intel_backlight", .default_dir);
    var sub = try tmp.dir.openDir(io, "intel_backlight", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "brightness", .data = "150\n" });
    try sub.writeFile(io, .{ .sub_path = "max_brightness", .data = "1000\n" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..base_len];

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/intel_backlight", .{base});

    try std.testing.expectEqual(@as(u32, 150), try current(dir, io));
}

test "list OOM frees each allocation exactly once" {
    const io = std.testing.io;

    var da = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(da.deinit() == .ok) catch @panic("leak");
    const backing = da.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "fake0");
    try tmp.dir.createDirPath(io, "fake1");
    try tmp.dir.createDirPath(io, "fake2");

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        const result = listIn(tmp.dir, io, "/fake-sysfs", failing.allocator());
        if (result) |paths| {
            try std.testing.expectEqual(@as(usize, 3), paths.len);
            for (paths) |path| failing.allocator().free(path);
            failing.allocator().free(paths);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

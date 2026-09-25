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
    value: ?[]const u8 = null,
    device: ?[]const u8 = null,
    list: bool = false,
    help: bool = false,
    version: bool = false,

    const Operation = enum { get, max, set, monitor };

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
            } else if (std.mem.eql(u8, arg, "monitor")) {
                if (self.operation != null or self.list) return error.TooManyOperations;
                self.operation = .monitor;
            } else if (std.mem.eql(u8, arg, "set")) {
                if (self.operation != null or self.list) return error.TooManyOperations;
                self.operation = .set;
                i += 1;
                if (i >= argv.len) return error.MissingValue;
                self.value = argv[i];
            } else {
                return error.UnknownOperation;
            }
        }
        return self;
    }

    fn parseValue(text: []const u8, current_value: u32, max_value: u32) !u32 {
        if (text.len == 0) return error.InvalidValue;

        var rest = text;
        var delta: i2 = 0;
        if (rest[0] == '+') {
            delta = 1;
            rest = rest[1..];
        } else if (rest[0] == '-') {
            delta = -1;
            rest = rest[1..];
        }
        if (rest.len == 0) return error.InvalidValue;

        var is_percent = false;
        if (rest[rest.len - 1] == '%') {
            is_percent = true;
            rest = rest[0 .. rest.len - 1];
        }
        if (rest.len == 0) return error.InvalidValue;

        const amount = std.fmt.parseInt(u64, rest, 10) catch return error.InvalidValue;

        const wide_current: u64 = current_value;
        const wide_max: u64 = max_value;
        const result: u64 = switch (delta) {
            0 => if (is_percent) (wide_max *| amount +| 50) / 100 else amount,
            1 => if (is_percent) wide_current +| (wide_max *| amount +| 50) / 100 else wide_current +| amount,
            -1 => if (is_percent) wide_current -| (wide_max *| amount +| 50) / 100 else wide_current -| amount,
            else => unreachable,
        };

        if (result > max_value) return max_value;
        if (result < 1) return 1;
        return @intCast(result);
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

fn isBacklightChange(event: []const u8, device_name: []const u8) bool {
    var action_change = false;
    var subsystem_backlight = false;
    var our_device = false;

    var parts = std.mem.splitScalar(u8, event, 0);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "ACTION=change")) {
            action_change = true;
        } else if (std.mem.eql(u8, part, "SUBSYSTEM=backlight")) {
            subsystem_backlight = true;
        } else if (std.mem.startsWith(u8, part, "DEVPATH=")) {
            if (std.mem.endsWith(u8, part, device_name)) our_device = true;
        } else if (std.mem.indexOfScalar(u8, part, '=') == null) {
            if (std.mem.endsWith(u8, part, device_name)) our_device = true;
        }
    }
    return action_change and subsystem_backlight and our_device;
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
        .set => {
            const text = args.value orelse fail("error: set needs a value\n", .{});
            const target = Args.parseValue(text, cur, max) catch fail("error: invalid value '{s}'\n", .{text});

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&path_buf, "{s}/brightness", .{dir});
            var file = std.Io.Dir.openFileAbsolute(io, file_path, .{ .mode = .write_only }) catch |err| {
                if (err == error.AccessDenied) fail("error: no permission to set brightness for '{s}' (install contrib/90-backlight.rules or run as root)\n", .{dev_name});
                fail("error: cannot set brightness for '{s}'\n", .{dev_name});
            };
            defer file.close(io);

            var text_buf: [32]u8 = undefined;
            const text_out = try std.fmt.bufPrint(&text_buf, "{d}\n", .{target});
            file.writeStreamingAll(io, text_out) catch fail("error: cannot set brightness for '{s}'\n", .{dev_name});

            try stdout.print("Device '{s}': {d}/{d} ({d}%)\n", .{ dev_name, target, max, percent(target, max) });
            try stdout.flush();
        },
        .monitor => {
            var nfd: ?i32 = null;
            {
                const rc = std.os.linux.socket(std.os.linux.AF.NETLINK, std.os.linux.SOCK.DGRAM, std.os.linux.NETLINK.KOBJECT_UEVENT);
                if (std.os.linux.errno(rc) == .SUCCESS) {
                    const fd: i32 = @intCast(rc);
                    const address = std.os.linux.sockaddr.nl{ .pid = 0, .groups = 1 };
                    if (std.os.linux.errno(std.os.linux.bind(fd, @ptrCast(&address), @intCast(@sizeOf(@TypeOf(address))))) == .SUCCESS) {
                        nfd = fd;
                    } else {
                        _ = std.os.linux.close(fd);
                    }
                }
                if (nfd == null) std.debug.print("warning: netlink unavailable, watching sysfs only\n", .{});
            }
            defer {
                if (nfd) |fd| _ = std.os.linux.close(fd);
            }

            var poll_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const poll_path = try std.fmt.bufPrintZ(&poll_buf, "{s}/actual_brightness", .{dir});
            const sysfs_fd: i32 = blk: {
                const rc = std.os.linux.open(poll_path, .{}, 0);
                if (std.os.linux.errno(rc) != .SUCCESS) fail("error: cannot watch brightness for '{s}'\n", .{dev_name});
                break :blk @intCast(rc);
            };
            defer _ = std.os.linux.close(sysfs_fd);

            try stdout.print("{s},{d},{d},{d}%\n", .{ dev_name, cur, max, percent(cur, max) });
            try stdout.flush();

            var last = cur;
            var buf: [8192]u8 = undefined;
            while (true) {
                var fds: [2]std.posix.pollfd = undefined;
                var count: usize = 0;
                if (nfd) |fd| {
                    fds[count] = .{ .fd = fd, .events = std.os.linux.POLL.IN, .revents = 0 };
                    count += 1;
                }
                fds[count] = .{ .fd = sysfs_fd, .events = std.os.linux.POLL.PRI | std.os.linux.POLL.ERR, .revents = 0 };
                count += 1;

                _ = try std.posix.poll(fds[0..count], -1);

                var matched = false;
                if (nfd) |fd| {
                    if (fds[0].revents != 0) {
                        const rc = std.os.linux.recvfrom(fd, &buf, buf.len, 0, null, null);
                        if (std.os.linux.errno(rc) != .SUCCESS) fail("error: lost event stream\n", .{});
                        matched = isBacklightChange(buf[0..@as(usize, @intCast(rc))], dev_name);
                    }
                }
                if (fds[count - 1].revents != 0) {
                    matched = true;
                    // Disarm with seek+read; close/reopen spins at 100% CPU.
                    if (std.os.linux.errno(std.os.linux.lseek(sysfs_fd, 0, std.os.linux.SEEK.SET)) != .SUCCESS) fail("error: lost event stream\n", .{});
                    var scratch: [32]u8 = undefined;
                    const read_rc = std.os.linux.read(sysfs_fd, &scratch, scratch.len);
                    if (std.os.linux.errno(read_rc) != .SUCCESS) fail("error: lost event stream\n", .{});
                }
                if (!matched) continue;

                const now = try current(dir, io);
                if (now == last) continue;
                last = now;
                try stdout.print("{s},{d},{d},{d}%\n", .{ dev_name, now, max, percent(now, max) });
                try stdout.flush();
            }
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

test "monitor operation" {
    try std.testing.expectEqual(Args.Operation.monitor, (try Args.parse(&.{ "backlightctl", "monitor" })).operation.?);
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "get", "monitor" }));
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "monitor", "get" }));
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "-l", "monitor" }));
    try std.testing.expectError(error.TooManyOperations, Args.parse(&.{ "backlightctl", "monitor", "-l" }));
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

test "set takes a value" {
    const args = try Args.parse(&.{ "backlightctl", "set", "+10%" });
    try std.testing.expectEqual(Args.Operation.set, args.operation.?);
    try std.testing.expectEqualStrings("+10%", args.value.?);
    try std.testing.expectError(error.MissingValue, Args.parse(&.{ "backlightctl", "set" }));
}

test "parseValue absolute" {
    try std.testing.expectEqual(@as(u32, 500), try Args.parseValue("500", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 6009), try Args.parseValue("999999", 5409, 6009));
}

test "parseValue absolute percent rounds half up" {
    try std.testing.expectEqual(@as(u32, 3005), try Args.parseValue("50%", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 601), try Args.parseValue("10%", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 6009), try Args.parseValue("100%", 5409, 6009));
}

test "parseValue deltas" {
    try std.testing.expectEqual(@as(u32, 5419), try Args.parseValue("+10", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 5359), try Args.parseValue("-50", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 6009), try Args.parseValue("+999999", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 1), try Args.parseValue("-5900", 5409, 6009));
}

test "parseValue percent deltas round half up" {
    try std.testing.expectEqual(@as(u32, 6009), try Args.parseValue("+10%", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 2404), try Args.parseValue("-50%", 5409, 6009));
}

test "parseValue clamps to min 1" {
    try std.testing.expectEqual(@as(u32, 1), try Args.parseValue("0", 5409, 6009));
    try std.testing.expectEqual(@as(u32, 3005), try Args.parseValue("50%", 5409, 6009));
}

test "parseValue rejects garbage" {
    for ([_][]const u8{ "", "%", "+", "-", "abc", "10%%", "+-", " 50", "50 ", "50-", "50%-" }) |bad| {
        try std.testing.expectError(error.InvalidValue, Args.parseValue(bad, 5409, 6009));
    }
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

test "backlight change for our device matches" {
    const event = "change@/devices/pci/backlight/intel_backlight\x00ACTION=change\x00SUBSYSTEM=backlight\x00DEVPATH=/devices/pci/backlight/intel_backlight\x00SEQNUM=1234\x00";
    try std.testing.expect(isBacklightChange(event, "intel_backlight"));
}

test "other subsystem does not match" {
    const event = "change@/devices/power_supply/BAT0\x00ACTION=change\x00SUBSYSTEM=power_supply\x00DEVPATH=/devices/power_supply/BAT0\x00SEQNUM=1235\x00";
    try std.testing.expect(!isBacklightChange(event, "intel_backlight"));
}

test "backlight add does not match" {
    const event = "add@/devices/pci/backlight/intel_backlight\x00ACTION=add\x00SUBSYSTEM=backlight\x00DEVPATH=/devices/pci/backlight/intel_backlight\x00SEQNUM=1236\x00";
    try std.testing.expect(!isBacklightChange(event, "intel_backlight"));
}

test "other backlight device does not match" {
    const event = "change@/devices/pci/backlight/acpi_video0\x00ACTION=change\x00SUBSYSTEM=backlight\x00DEVPATH=/devices/pci/backlight/acpi_video0\x00SEQNUM=1237\x00";
    try std.testing.expect(!isBacklightChange(event, "intel_backlight"));
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

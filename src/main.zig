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
    help: bool = false,
    version: bool = false,

    const ParseError = error{
        UnknownFlag,
        UnknownOperation,
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
                } else {
                    return error.UnknownFlag;
                }
            } else {
                return error.UnknownOperation;
            }
        }
        return self;
    }
};

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

    fail("error: invalid arguments; try 'backlightctl --help'\n", .{});
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

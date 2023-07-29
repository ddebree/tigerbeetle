//! The purpose of `flags` is to define standard behavior for parsing CLI arguments and provide
//! a specific parsing library, implementing this behavior.
//!
//! These are TigerBeetle CLI guidelines:
//!
//!    - The main principle is robustness --- make operator errors harder to make.
//!    - For production usage, avoid defaults.
//!    - Thoroughly validate options.
//!    - In particular, check that no options are repeated.
//!    - Use only long options (`--addresses`).
//!    - Exception: `-h/--help` is allowed.
//!    - Use `--key=value` syntax for an option with an argument.
//!      Don't use `--key value`, as that can be ambiguous (e.g., `--key --verbose`).
//!    - Use subcommand syntax when appropriate.
//!    - Use positional arguments when appropriate.
//!
//! Design choices for this particular `flags` library:
//!
//! - Be a 80% solution. Parsing arguments is a surprisingly vast topic: auto-generated help,
//!   bash completions, typo correction. Rather than providing a definitive solution, `flags`
//!   is just one possible option. It is ok to re-implement arg parsing in a different way, as long
//!   as the CLI guidelines are observed.
//!
//! - No auto-generated help. Zig doesn't expose doc comments through `@typeInfo`, so its hard to
//!   implement auto-help nicely. Additionally, fully hand-crafted `--help` message can be of
//!   higher quality.
//!
//! - Fatal errors. It might be "cleaner" to use `try` to propagate the error to the caller, but
//!   during early CLI parsing, it is much simpler to terminate the process directly and save the
//!   caller the hassle of propagating errors. The `fatal` function is public, to allow the caller
//!   to run additional validation or parsing using the same error reporting mechanism.
//!
//!   Fatal errors make testing awkward, we'll need to wait for this Zig issue to test this code:
//!   <https://github.com/ziglang/zig/issues/1356>.
//!
//! - Concise DSL. Most cli parsing is done for ad-hoc tools like benchmarking, where the ability to
//!   quickly add a new argument is valuable. As this is a 80% solution, production code may use
//!   more verbose approach if it gives better UX.
//!
//! - Caller manages ArgsIterator. ArgsIterator owns the backing memory of the args, so we let the
//!   caller to manage the lifetime. The caller should be skipping program name.

const std = @import("std");
const assert = std.debug.assert;

/// Format and print an error message to stderr, then exit with an exit code of 1.
pub fn fatal(comptime fmt_string: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("error: " ++ fmt_string ++ "\n", args) catch {};
    std.os.exit(1);
}

/// Parse CLI arguments for subcommands specified as Zig `union(enum)`:
///
/// ```
/// const cli_args = parse_commands(&args, union(enum) {
///    start: struct { addresses: []const u8, replica: u32 },
///    format: struct {
///        verbose: bool = false,
///        positional: struct {
///            path: []const u8,
///        }
///    },
///
///    pub const help =
///        \\ tigerbeetle start --addresses=<addresses> --replica=<replica>
///        \\ tigerbeetle format [--verbose]
/// })
/// ```
///
/// `positional` field is treated specially, it designates positional arguments.
///
/// If `pub const help` declaration is present, it is used to implement `-h/--help` argument.
pub fn parse_commands(args: *std.process.ArgIterator, comptime Commands: type) Commands {
    assert(@typeInfo(Commands) == .Union);

    const first_arg = args.next() orelse fatal("subcommand required", .{});

    // NB: help must be declared as *pub* const to be visible here.
    if (@hasDecl(Commands, "help")) {
        if (std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "--help")) {
            std.io.getStdOut().writeAll(Commands.help) catch std.os.exit(1);
            std.os.exit(0);
        }
    }

    inline for (comptime std.meta.fields(Commands)) |field| {
        comptime assert(std.mem.indexOf(u8, field.name, "_") == null);
        if (std.mem.eql(u8, first_arg, field.name)) {
            return @unionInit(Commands, field.name, parse_flags(args, field.field_type));
        }
    }
    fatal("unknown subcommand: '{s}'", .{first_arg});
}

/// Parse CLI arguments for a single command specified as Zig `struct`:
///
/// ```
/// const cli_args = parse_commands(&args, struct {
///    verbose: bool = false,
///    replica: u32,
///    positional: struct { path: []const u8 = "0_0.tigerbeetle" },
/// })
/// ```
pub fn parse_flags(args: *std.process.ArgIterator, comptime Flags: type) Flags {
    if (Flags == void) {
        if (args.next()) |arg| {
            fatal("unexpected argument: '{s}'", .{arg});
        }
        return {};
    }

    assert(@typeInfo(Flags) == .Struct);

    comptime var fields: [16]std.builtin.Type.StructField = undefined;
    comptime var field_count = 0;

    comptime var positional_fields: []const std.builtin.Type.StructField = &.{};

    comptime for (std.meta.fields(Flags)) |field| {
        if (std.mem.eql(u8, field.name, "positional")) {
            assert(@typeInfo(field.field_type) == .Struct);
            positional_fields = std.meta.fields(field.field_type);
            for (positional_fields) |positional_field| {
                assert(default_value(positional_field) == null);
                assert_valid_value_type(positional_field.field_type);
            }
        } else {
            fields[field_count] = field;
            field_count += 1;
            if (field.field_type == bool) {
                assert(default_value(field) == false); // boolean flags should have explicit default
            } else {
                assert_valid_value_type(field.field_type);
            }
        }
    };

    var result: Flags = undefined;
    var counts: std.enums.EnumFieldStruct(Flags, u32, 0) = .{};

    // When parsing arguments, we must consider longer arguments first, such that `--foo-bar=92` is
    // not confused for a misspelled `--foo=92`. Using `std.sort` for comptime-only values does not
    // work, so open-code insertion sort, and comptime assert order during the actual parsing.
    comptime {
        for (fields[0..field_count]) |*field_right, i| {
            for (fields[0..i]) |*field_left| {
                if (field_left.name.len < field_right.name.len) {
                    std.mem.swap(std.builtin.Type.StructField, field_left, field_right);
                }
            }
        }
    }

    next_arg: while (args.next()) |arg| {
        comptime var field_len_prev = std.math.maxInt(usize);
        inline for (fields[0..field_count]) |field| {
            const flag = comptime flag_name(field);

            comptime assert(field_len_prev >= field.name.len);
            field_len_prev = field.name.len;
            if (std.mem.startsWith(u8, arg, flag)) {
                @field(counts, field.name) += 1;
                const flag_value = parse_flag(field.field_type, flag, arg);
                @field(result, field.name) = flag_value;
                continue :next_arg;
            }
        }

        if (@hasField(Flags, "positional")) {
            counts.positional += 1;
            inline for (positional_fields) |positional_field, positional_index| {
                const flag = comptime flag_name_positional(positional_field);

                if (arg.len == 0) fatal("{s}: empty argument", .{flag});
                // Prevent ambiguity between a flag and positional argument value. We could add
                // support for bare ` -- ` as a disambiguation mechanism once we have a real
                // use-case.
                if (arg[0] == '-') fatal("unexpected argument: '{s}'", .{arg});

                @field(result.positional, positional_field.name) =
                    parse_value(positional_field.field_type, flag, arg);
                if (positional_index + 1 == counts.positional) {
                    continue :next_arg;
                }
            }
        }

        fatal("unexpected argument: '{s}'", .{arg});
    }

    inline for (fields[0..field_count]) |field| {
        const flag = flag_name(field);
        switch (@field(counts, field.name)) {
            0 => if (default_value(field)) |default| {
                @field(result, field.name) = default;
            } else {
                fatal("{s}: argument is required", .{flag});
            },
            1 => {},
            else => fatal("{s}: duplicate argument", .{flag}),
        }
    }

    if (@hasField(Flags, "positional")) {
        assert(counts.positional <= positional_fields.len);
        inline for (positional_fields) |positional_field, positional_index| {
            if (counts.positional == positional_index) {
                const flag = comptime flag_name_positional(positional_field);
                fatal("{s}: argument is required", .{flag});
            }
        }
    }

    return result;
}

fn assert_valid_value_type(comptime T: type) void {
    if (T == []const u8 or T == [:0]const u8 or T == ByteSize or @typeInfo(T) == .Int) return;
    @compileLog("unsupported type", T);
    comptime unreachable;
}

/// Parse, e.g., `--cluster=123` into `123` integer
fn parse_flag(comptime T: type, comptime flag: []const u8, arg: [:0]const u8) T {
    comptime assert(flag[0] == '-' and flag[1] == '-');

    if (T == bool) {
        if (!std.mem.eql(u8, arg, flag)) {
            fatal("{s}: argument does not require a value in '{s}'", .{ flag, arg });
        }
        return true;
    }

    const value = parse_flag_split_value(flag, arg);
    assert(value.len > 0);
    return parse_value(T, flag, value);
}

/// Splits the value part from a `--arg=value` syntax.
fn parse_flag_split_value(comptime flag: []const u8, arg: [:0]const u8) [:0]const u8 {
    comptime assert(flag[0] == '-' and flag[1] == '-');
    assert(std.mem.startsWith(u8, arg, flag));

    const value = arg[flag.len..];
    if (value.len == 0) {
        fatal("{s}: expected value separator '='", .{flag});
    }
    if (value[0] != '=') {
        fatal(
            "{s}: expected value separator '=', but found '{c}' in '{s}'",
            .{ flag, value[0], arg },
        );
    }
    if (value.len == 1) fatal("{s}: argument requires a value", .{flag});
    return value[1..];
}

fn parse_value(comptime T: type, comptime flag: []const u8, value: [:0]const u8) T {
    comptime assert(T != bool);
    comptime assert((flag[0] == '-' and flag[1] == '-') or flag[0] == '<');
    assert(value.len > 0);

    if (T == []const u8 or T == [:0]const u8) return value;
    if (T == ByteSize) return parse_value_size(flag, value);
    if (@typeInfo(T) == .Int) return parse_value_int(T, flag, value);
    comptime unreachable;
}

/// Parse string value into an integer, providing a nice error message for the user.
fn parse_value_int(comptime T: type, comptime flag: []const u8, value: [:0]const u8) T {
    comptime assert((flag[0] == '-' and flag[1] == '-') or flag[0] == '<');

    return std.fmt.parseInt(T, value, 10) catch |err| {
        fatal("{s}: expected an integer value, but found '{s}' ({s})", .{
            flag, value, switch (err) {
                error.Overflow => "value too large",
                error.InvalidCharacter => "invalid digit",
            },
        });
    };
}

pub const ByteSize = struct { bytes: u64 };
fn parse_value_size(comptime flag: []const u8, value: []const u8) ByteSize {
    comptime assert((flag[0] == '-' and flag[1] == '-') or flag[0] == '<');

    const units = .{
        .{ &[_][]const u8{ "TiB", "tib", "TB", "tb" }, 1024 * 1024 * 1024 * 1024 },
        .{ &[_][]const u8{ "GiB", "gib", "GB", "gb" }, 1024 * 1024 * 1024 },
        .{ &[_][]const u8{ "MiB", "mib", "MB", "mb" }, 1024 * 1024 },
        .{ &[_][]const u8{ "KiB", "kib", "KB", "kb" }, 1024 },
    };

    const unit: struct { suffix: []const u8, scale: u64 } = unit: inline for (units) |unit| {
        const suffixes = unit[0];
        const scale = unit[1];
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, value, suffix)) {
                break :unit .{ .suffix = suffix, .scale = scale };
            }
        }
    } else break :unit .{ .suffix = "", .scale = 1 };

    assert(std.mem.endsWith(u8, value, unit.suffix));
    const value_numeric = value[0 .. value.len - unit.suffix.len];

    const amount = std.fmt.parseUnsigned(u64, value_numeric, 10) catch |err| {
        fatal("{s}: expected a size, but found '{s}' ({s})", .{
            flag, value, switch (err) {
                error.Overflow => "value too large",
                error.InvalidCharacter => "invalid digit",
            },
        });
    };

    var bytes: u64 = undefined;
    if (@mulWithOverflow(u64, amount, unit.scale, &bytes)) {
        fatal("{s}: expected a size, but found '{s}' (value too large)", .{
            flag, value,
        });
    }
    return ByteSize{ .bytes = bytes };
}

test parse_value_size {
    const kib = 1024;
    const mib = kib * 1024;
    const gib = mib * 1024;
    const tib = gib * 1024;

    const cases = .{
        .{ 0, "0" },
        .{ 1, "1" },
        .{ 140737488355328, "140737488355328" },
        .{ 140737488355328, "128TiB" },
        .{ 1 * tib, "1TiB" },
        .{ 10 * tib, "10tib" },
        .{ 100 * tib, "100TB" },
        .{ 1000 * tib, "1000tb" },
        .{ 1 * gib, "1GiB" },
        .{ 10 * gib, "10gib" },
        .{ 100 * gib, "100GB" },
        .{ 1000 * gib, "1000gb" },
        .{ 1 * mib, "1MiB" },
        .{ 10 * mib, "10mib" },
        .{ 100 * mib, "100MB" },
        .{ 1000 * mib, "1000mb" },
        .{ 1 * kib, "1KiB" },
        .{ 10 * kib, "10kib" },
        .{ 100 * kib, "100KB" },
        .{ 1000 * kib, "1000kb" },
    };

    inline for (cases) |case| {
        const want = case[0];
        const input = case[1];
        const got = parse_value_size("--size", input);
        try std.testing.expectEqual(want, got);
    }
}

fn flag_name(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime assert(!std.mem.eql(u8, field.name, "positional"));

    comptime var result: []const u8 = "--";
    comptime {
        var index = 0;
        while (std.mem.indexOf(u8, field.name[index..], "_")) |i| {
            result = result ++ field.name[index..][0..i] ++ "-";
            index = index + i + 1;
        }
        result = result ++ field.name[index..];
    }
    return result;
}

test flag_name {
    const field = @typeInfo(struct { enable_statsd: bool }).fields[0];
    try std.testing.expectEqualStrings(flag_name(field), "--enable-statsd");
}

fn flag_name_positional(comptime field: std.builtin.Type.StructField) []const u8 {
    comptime assert(std.mem.indexOf(u8, field.name, "_") == null);
    return "<" ++ field.name ++ ">";
}

/// This is essentially `field.default_value`, but with a useful type instead of `?*anyopaque`.
fn default_value(comptime field: std.builtin.Type.StructField) ?field.field_type {
    return if (field.default_value) |default_opaque|
        @ptrCast(
            *const field.field_type,
            @alignCast(@alignOf(field.field_type), default_opaque),
        ).*
    else
        null;
}

test "flags" {
    const Snap = @import("./testing/snaptest.zig").Snap;
    const snap = Snap.snap;

    const T = struct {
        const T = @This();

        gpa: std.mem.Allocator,
        buf: std.ArrayList(u8),
        zig: []const u8,

        fn init(gpa: std.mem.Allocator) !T {
            return .{
                .gpa = gpa,
                .buf = std.ArrayList(u8).init(gpa),
                .zig = std.os.getenv("ZIG_EXE") orelse return error.SkipZigTest,
            };
        }

        fn deinit(t: *T) void {
            t.buf.deinit();
            t.* = undefined;
        }

        fn check(t: *T, cli: []const []const u8, want: Snap) !void {
            const argv = try t.gpa.alloc([]const u8, cli.len + 4);
            defer t.gpa.free(argv);

            argv[0] = t.zig;
            argv[1] = "run";
            argv[2] = comptime std.fs.path.dirname(@src().file).? ++ "/flags_test_program.zig";
            argv[3] = "--";
            for (cli) |cli_arg, i| {
                argv[i + 4] = cli_arg;
            }
            if (cli.len > 0) {
                assert(argv[argv.len - 1].ptr == cli[cli.len - 1].ptr);
            }

            const exec_result = try std.ChildProcess.exec(.{
                .allocator = t.gpa,
                .argv = argv,
            });
            defer t.gpa.free(exec_result.stdout);
            defer t.gpa.free(exec_result.stderr);

            t.buf.clearRetainingCapacity();

            if (exec_result.term.Exited != 0) {
                try t.buf.writer().print("status: {}\n", .{exec_result.term.Exited});
            }
            if (exec_result.stdout.len > 0) {
                try t.buf.writer().print("stdout:\n{s}", .{exec_result.stdout});
            }
            if (exec_result.stderr.len > 0) {
                try t.buf.writer().print("stderr:\n{s}", .{exec_result.stderr});
            }

            try want.diff(t.buf.items);
        }
    };

    var t = try T.init(std.testing.allocator);
    defer t.deinit();

    try t.check(&.{"empty"}, snap(@src(),
        \\stdout:
        \\empty
        \\
    ));

    try t.check(&.{}, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: subcommand required
        \\
    ));

    try t.check(&.{"bogus"}, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: unknown subcommand: 'bogus'
        \\
    ));

    try t.check(&.{"values"}, snap(@src(),
        \\stdout:
        \\int: 0
        \\size: 0
        \\boolean: false
        \\path: not-set
        \\
    ));

    try t.check(&.{ "values", "--int=92", "--size=1GiB", "--boolean", "--path=/home" }, snap(@src(),
        \\stdout:
        \\int: 92
        \\size: 1073741824
        \\boolean: true
        \\path: /home
        \\
    ));

    try t.check(&.{ "values", "--int" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --int: expected value separator '='
        \\
    ));

    try t.check(&.{ "values", "--int=" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --int: argument requires a value
        \\
    ));

    try t.check(&.{ "values", "--integer" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --int: expected value separator '=', but found 'e' in '--integer'
        \\
    ));

    try t.check(&.{ "values", "--int", "92" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --int: expected value separator '='
        \\
    ));

    try t.check(&.{ "values", "--int=XCII" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --int: expected an integer value, but found 'XCII' (invalid digit)
        \\
    ));

    try t.check(&.{ "values", "--int=44444444444444444444" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --int: expected an integer value, but found '44444444444444444444' (value too large)
        \\
    ));

    try t.check(&.{"--int=92"}, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: unknown subcommand: '--int=92'
        \\
    ));

    try t.check(&.{"required"}, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --foo: argument is required
        \\
    ));

    try t.check(&.{ "required", "--foo=1" }, snap(@src(),
        \\status: 1
        \\stderr:
        \\error: --bar: argument is required
        \\
    ));

    try t.check(&.{ "required", "--bar=1", "--foo=1" }, snap(@src(),
        \\stdout:
        \\foo: 1
        \\bar: 1
        \\
    ));
}

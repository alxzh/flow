const std = @import("std");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");
const root = @import("soft_root").root;

pub const Error = error{ OutOfMemory, GitNotFound, GitCallFailed, WriteFailed };

const log_execute = false;

/// Backend-neutral actor namespace; Project only ever sees "vcs".
const module_name = "vcs";
const git_binary_name = "git";

pub fn workspace_path(context_: usize, cwd: []const u8) Error!void {
    const fn_name = @src().fn_name;
    try git(context_, cwd, .{ "rev-parse", "--show-toplevel" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r");
                if (trimmed.len == 0) continue;
                parent.send(.{ module_name, context, fn_name, trimmed }) catch {};
                return;
            }
        }
    }.result, exit_null_on_error(fn_name));
}

pub fn current_branch(context_: usize, cwd: []const u8) Error!void {
    const fn_name = @src().fn_name;
    try git(context_, cwd, .{ "rev-parse", "--abbrev-ref", "HEAD" }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r");
                if (trimmed.len == 0) continue;
                parent.send(.{ module_name, context, fn_name, trimmed }) catch {};
                return;
            }
        }
    }.result, exit_null_on_error(fn_name));
}

pub fn workspace_files(context: usize, cwd: []const u8) Error!void {
    return if (is_file_in(cwd, ".gitmodules"))
        git_nul_output(
            context,
            cwd,
            @src().fn_name,
            .{ "ls-files", "-z", "--cached", "--exclude-standard", "--recurse-submodules" },
        )
    else
        git_nul_output(
            context,
            cwd,
            @src().fn_name,
            .{ "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        );
}

pub fn workspace_ignored_files(context: usize, cwd: []const u8) Error!void {
    return git_nul_output(
        context,
        cwd,
        @src().fn_name,
        .{ "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--ignored" },
    );
}

const StatusRecordType = enum {
    @"#", // header
    @"1", // ordinary file
    @"2", // rename or copy
    u, // unmerged file
    @"?", // untracked file
    @"!", // ignored file
};

pub fn status(context_: usize, cwd: []const u8) Error!void {
    const tag = @src().fn_name;
    try git_err_delimited(context_, cwd, .{
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
        "--branch",
        "--show-stash",
        // "--untracked-files=no",
        "--null",
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it_ = std.mem.splitScalar(u8, output, 0);
            while (it_.next()) |line| {
                var it = std.mem.splitScalar(u8, line, ' ');
                const rec_type = if (it.next()) |type_tag|
                    std.meta.stringToEnum(StatusRecordType, type_tag) orelse continue
                else
                    continue;
                switch (rec_type) {
                    .@"#" => { // header
                        const name = it.next() orelse return;
                        const value1 = it.next() orelse return;
                        const value2 = it.next();
                        if (std.mem.eql(u8, name, "branch.head")) {
                            parent.send(.{ module_name, context, tag, "branch", value1 }) catch {};
                        } else if (std.mem.eql(u8, name, "branch.ab")) {
                            const behind = value2 orelse return;
                            parent.send(.{ module_name, context, tag, "ahead", value1 }) catch {};
                            parent.send(.{ module_name, context, tag, "behind", behind }) catch {};
                        } else if (std.mem.eql(u8, name, "stash")) {
                            parent.send(.{ module_name, context, tag, "stash", value1 }) catch {};
                        } else {
                            // branch.oid, branch.upstream: no normalized event.
                        }
                    },
                    .@"1", .@"2", .u => {
                        // A type-2 record's origPath is the next NUL field. It
                        // may arrive in the next delimiter-buffered callback;
                        // consume it when present, otherwise that callback
                        // will harmlessly skip it as an unknown record.
                        if (rec_type == .@"2") _ = it_.next();
                        parent.send(.{ module_name, context, tag, "changed" }) catch {};
                    },
                    .@"?" => {
                        parent.send(.{ module_name, context, tag, "untracked" }) catch {};
                    },
                    .@"!" => {},
                }
            }
        }
    }.result, log_err, exit_null(tag), 0);
}

pub fn new_or_modified_files(context_: usize, cwd: []const u8) Error!void {
    const tag = @src().fn_name;
    try git_err_delimited(context_, cwd, .{
        "--no-optional-locks",
        "status",
        "--porcelain=v2",
        "--null",
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var files = parseChangedFiles(allocator, output) catch return;
            defer freeChangedFiles(allocator, &files);
            for (files.items) |file|
                parent.send(.{ module_name, context, tag, file.status, file.path }) catch {};
        }
    }.result, log_err, exit_null(tag), 0);
}

pub const ChangedFile = struct {
    status: u8,
    path: []const u8,
};

pub fn freeChangedFiles(allocator_: std.mem.Allocator, files: *std.ArrayListUnmanaged(ChangedFile)) void {
    for (files.items) |file| allocator_.free(file.path);
    files.deinit(allocator_);
}

/// Parse NUL-separated porcelain-v2 records into changed-file picker entries.
/// Pure (no I/O); the async handler above is a thin sender over this.
/// Ordinary record: `1 <XY> <subm> <mH> <mI> <mW> <hH> <hI> <path>`.
/// Rename record: `2 <XY> <subm> <mH> <mI> <mW> <hH> <hI> <X><score> <path>`
/// followed by an `<origPath>` NUL segment which is always consumed.
pub fn parseChangedFiles(allocator_: std.mem.Allocator, output: []const u8) error{OutOfMemory}!std.ArrayListUnmanaged(ChangedFile) {
    var files: std.ArrayListUnmanaged(ChangedFile) = .empty;
    errdefer freeChangedFiles(allocator_, &files);
    var records = std.mem.splitScalar(u8, output, 0);
    while (records.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        const type_tag = fields.next() orelse continue;
        const rec_type = std.meta.stringToEnum(StatusRecordType, type_tag) orelse continue;
        switch (rec_type) {
            .@"1" => {
                const xy = fields.next() orelse continue;
                const subm = fields.next() orelse continue;
                for (0..5) |_| _ = fields.next() orelse break;
                const file_status = classifyChangedFile(xy, subm) orelse continue;
                const path = try takePathFields(allocator_, &fields);
                const owned = path orelse continue;
                (try files.addOne(allocator_)).* = .{ .status = file_status, .path = owned };
            },
            .@"2" => {
                const xy = fields.next() orelse {
                    _ = records.next();
                    continue;
                };
                for (0..7) |_| _ = fields.next() orelse break;
                const path = try takePathFields(allocator_, &fields);
                _ = records.next(); // consume <origPath> segment
                if (xy.len == 0 or xy[0] != 'R') {
                    if (path) |owned| allocator_.free(owned);
                    continue;
                }
                const owned = path orelse continue;
                (try files.addOne(allocator_)).* = .{ .status = '+', .path = owned };
            },
            .@"?" => {
                const path = try takePathFields(allocator_, &fields);
                const owned = path orelse continue;
                (try files.addOne(allocator_)).* = .{ .status = '+', .path = owned };
            },
            else => {
                // Omit headers, unmerged, ignored and other statuses.
                continue;
            },
        }
    }
    return files;
}

fn takePathFields(allocator_: std.mem.Allocator, fields: *std.mem.SplitIterator(u8, .scalar)) error{OutOfMemory}!?[]u8 {
    var path: std.ArrayListUnmanaged(u8) = .empty;
    errdefer path.deinit(allocator_);
    while (fields.next()) |part| {
        if (path.items.len > 0) try path.append(allocator_, ' ');
        try path.appendSlice(allocator_, part);
    }
    if (path.items.len == 0) {
        path.deinit(allocator_);
        return null;
    }
    return try path.toOwnedSlice(allocator_);
}

/// Classify an ordinary porcelain-v2 entry from its XY status field and
/// submodule state field. Returns '+' for added, '~' for modified, null to
/// omit (deletes, submodules).
pub fn classifyChangedFile(xy: []const u8, subm: []const u8) ?u8 {
    if (xy.len == 0) return null;
    if (xy[0] == 'A') return '+';
    if (xy[0] == 'M' or (xy.len > 1 and xy[1] == 'M')) {
        if (subm.len > 0 and subm[0] == 'S') return null;
        return '~';
    }
    return null;
}

pub fn file_id(context_: usize, cwd: []const u8, file_path: []const u8) Error!void {
    const tag = "file_id";
    var arg: std.Io.Writer.Allocating = .init(allocator);
    defer arg.deinit();
    const path = pathRelativeToCwd(cwd, file_path);
    if (path.len == 0)
        try arg.writer.print("HEAD", .{})
    else if (std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "./"))
        try arg.writer.print("HEAD:{s}", .{path})
    else
        // In revision:path syntax, a leading ./ makes the path relative to
        // the explicit -C working directory rather than the repository root.
        try arg.writer.print("HEAD:./{s}", .{path});
    try git(context_, cwd, .{ "rev-parse", arg.written() }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r");
                if (trimmed.len == 0) continue;
                parent.send(.{ module_name, context, tag, trimmed }) catch {};
                return;
            }
        }
    }.result, exit_null(tag));
}

pub fn file_content(context_: usize, cwd: []const u8, file_path: []const u8, file_id_: []const u8) Error!void {
    _ = file_path;
    const tag = "file_content";
    try git_raw(context_, cwd, .{ "cat-file", "-p", file_id_ }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

pub fn check_ignore(context_: usize, cwd: []const u8, file_path: []const u8) Error!void {
    const tag = @src().fn_name;
    try git(context_, cwd, .{ "check-ignore", "-q", "--", file_path }, struct {
        fn result(_: usize, _: tp.pid_ref, _: []const u8) void {}
    }.result, exit_result(tag));
}

fn git_line_output(context_: usize, cwd: []const u8, comptime tag: []const u8, cmd: anytype) Error!void {
    try git_err(context_, cwd, cmd, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, log_err, exit_null(tag));
}

fn git_nul_output(context_: usize, cwd: []const u8, comptime tag: []const u8, cmd: anytype) Error!void {
    try git_err_delimited(context_, cwd, cmd, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, 0);
            while (it.next()) |value| if (value.len > 0)
                parent.send(.{ module_name, context, tag, value }) catch {};
        }
    }.result, log_err, exit_null(tag), 0);
}

fn git(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return git_err(context, cwd, cmd, out, noop, exit);
}

fn git_raw(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return git_err_with_options(context, cwd, cmd, out, noop, exit, false, '\n');
}

fn git_err(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return git_err_with_options(context, cwd, cmd, out, err, exit, true, '\n');
}

fn git_err_delimited(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
    delimiter: u8,
) Error!void {
    return git_err_with_options(context, cwd, cmd, out, err, exit, true, delimiter);
}

fn git_err_with_options(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
    line_buffered: bool,
    stdout_delimiter: u8,
) Error!void {
    const cbor = @import("cbor");
    const git_binary = get_git() orelse return error.GitNotFound;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const writer = &buf.writer;
    switch (@typeInfo(@TypeOf(cmd))) {
        .@"struct" => |info| if (info.is_tuple) {
            try cbor.writeArrayHeader(writer, info.fields.len + 3);
            try cbor.writeValue(writer, git_binary);
            try cbor.writeValue(writer, "-C");
            try cbor.writeValue(writer, cwd);
            inline for (info.fields) |f|
                try cbor.writeValue(writer, @field(cmd, f.name));
            return shell.execute(allocator, .{ .buf = buf.written() }, .{
                .context = context,
                .out = to_shell_output_handler(out),
                .err = to_shell_output_handler(err),
                .exit = exit,
                .log_execute = log_execute,
                .line_buffered = line_buffered,
                .stdout_delimiter = stdout_delimiter,
            }) catch error.GitCallFailed;
        },
        else => {},
    }
    @compileError("git command should be a tuple: " ++ @typeName(@TypeOf(cmd)));
}

fn exit_null(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, _: i64) void {
            parent.send(.{ module_name, context, tag, null }) catch {};
        }
    }.exit;
}

fn exit_null_on_error(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
            if (exit_code != 0)
                parent.send(.{ module_name, context, tag, null }) catch {};
        }
    }.exit;
}

fn exit_result(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code: i64) void {
            parent.send(.{ module_name, context, tag, exit_code }) catch {};
        }
    }.exit;
}

const OutputHandler = fn (context: usize, parent: tp.pid_ref, output: []const u8) void;
const ExitHandler = shell.ExitHandler;

fn to_shell_output_handler(handler: anytype) shell.OutputHandler {
    return struct {
        fn out(context: usize, parent: tp.pid_ref, _: []const u8, output: []const u8) void {
            handler(context, parent, output);
        }
    }.out;
}

fn log_err(_: usize, _: tp.pid_ref, output: []const u8) void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| if (line.len > 0)
        std.log.err("{s}: {s}", .{ module_name, line });
}

fn noop(_: usize, _: tp.pid_ref, _: []const u8) void {}

var git_path: ?struct {
    path: ?[:0]const u8 = null,
} = null;

const allocator = std.heap.c_allocator;

fn get_git() ?[]const u8 {
    if (git_path) |p| return p.path;
    const path = bin_path.find_binary_in_path(allocator, git_binary_name) catch null;
    git_path = .{ .path = path };
    return path;
}

pub fn is_available() bool {
    return get_git() != null;
}

pub fn blame(context_: usize, cwd: []const u8, file_path: []const u8) !void {
    const tag = @src().fn_name;
    try git(context_, cwd, .{
        "blame",
        "--incremental",
        "HEAD",
        "--",
        file_path,
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

fn pathRelativeToCwd(cwd: []const u8, file_path: []const u8) []const u8 {
    if (cwd.len == 0 or !std.fs.path.isAbsolute(file_path)) return file_path;
    if (file_path.len <= cwd.len or !std.mem.eql(u8, file_path[0..cwd.len], cwd)) return file_path;
    if (std.fs.path.isSep(cwd[cwd.len - 1])) return file_path[cwd.len..];
    if (!std.fs.path.isSep(file_path[cwd.len])) return file_path;
    return file_path[cwd.len + 1 ..];
}

fn is_file_in(cwd: []const u8, rel_path: []const u8) bool {
    const io = root.get_io();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ cwd, std.fs.path.sep, rel_path }) catch return false;
    const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch return false;
    defer file.close(io);
    return true;
}

const module_name_for_test = module_name;

test "classifyChangedFile maps XY and submodule state" {
    const t = std.testing;
    try t.expectEqual(@as(?u8, '+'), classifyChangedFile("A.", "N..."));
    try t.expectEqual(@as(?u8, '+'), classifyChangedFile("AM", "N..."));
    try t.expectEqual(@as(?u8, '~'), classifyChangedFile(".M", "N..."));
    try t.expectEqual(@as(?u8, '~'), classifyChangedFile("M.", "N..."));
    try t.expectEqual(@as(?u8, '~'), classifyChangedFile("MM", "N..."));
    try t.expect(classifyChangedFile(".D", "N...") == null);
    try t.expect(classifyChangedFile("D.", "N...") == null);
    try t.expect(classifyChangedFile(".M", "S...") == null);
    try t.expect(classifyChangedFile("", "N...") == null);
}

test "parseChangedFiles covers ordinary records" {
    const t = std.testing;
    const alloc = t.allocator;
    const output =
        "1 .M N... 100644 100644 100644 abc123 abc123 src/foo.zig\x00" ++
        "1 A. N... 000000 100644 100644 000000 def456 new.txt\x00" ++
        "1 .D N... 100644 000000 000000 abc123 000000 gone.txt\x00" ++
        "1 .M S... 100644 100644 100644 abc123 abc123 submod\x00" ++
        "1 M. N... 100644 100644 100644 abc123 abc123 sp ace.txt\x00";
    var files = try parseChangedFiles(alloc, output);
    defer freeChangedFiles(alloc, &files);
    try t.expectEqual(@as(usize, 3), files.items.len);
    try t.expectEqual(@as(u8, '~'), files.items[0].status);
    try t.expectEqualStrings("src/foo.zig", files.items[0].path);
    try t.expectEqual(@as(u8, '+'), files.items[1].status);
    try t.expectEqualStrings("new.txt", files.items[1].path);
    try t.expectEqual(@as(u8, '~'), files.items[2].status);
    try t.expectEqualStrings("sp ace.txt", files.items[2].path);
}

test "parseChangedFiles covers rename, copy and untracked records" {
    const t = std.testing;
    const alloc = t.allocator;
    const output =
        "2 R. N... 100644 100644 100644 abc123 abc123 R100 new.txt\x00old.txt\x00" ++
        "2 C. N... 100644 100644 100644 abc123 abc123 C100 copy.txt\x00orig2.txt\x00" ++
        "? loose.txt\x00" ++
        "u UU N... 100644 100644 100644 100644 abc123 abc123 abc123 conflict.txt\x00";
    var files = try parseChangedFiles(alloc, output);
    defer freeChangedFiles(alloc, &files);
    try t.expectEqual(@as(usize, 2), files.items.len);
    try t.expectEqual(@as(u8, '+'), files.items[0].status);
    try t.expectEqualStrings("new.txt", files.items[0].path);
    try t.expectEqual(@as(u8, '+'), files.items[1].status);
    try t.expectEqualStrings("loose.txt", files.items[1].path);
}

test "pathRelativeToCwd normalizes project files" {
    const t = std.testing;
    try t.expectEqualStrings("src/a.zig", pathRelativeToCwd("/repo", "/repo/src/a.zig"));
    try t.expectEqualStrings("src/a.zig", pathRelativeToCwd("/repo", "src/a.zig"));
    try t.expectEqualStrings("src/a.zig", pathRelativeToCwd("/", "/src/a.zig"));
    try t.expectEqualStrings("/repository/a.zig", pathRelativeToCwd("/repo", "/repository/a.zig"));
}

test "parseChangedFiles tolerates rename split before origPath" {
    const t = std.testing;
    const alloc = t.allocator;
    var first = try parseChangedFiles(
        alloc,
        "2 R. N... 100644 100644 100644 abc123 abc123 R100 new.txt\x00",
    );
    defer freeChangedFiles(alloc, &first);
    try t.expectEqual(@as(usize, 1), first.items.len);
    try t.expectEqualStrings("new.txt", first.items[0].path);

    var second = try parseChangedFiles(alloc, "old.txt\x00? loose.txt\x00");
    defer freeChangedFiles(alloc, &second);
    try t.expectEqual(@as(usize, 1), second.items.len);
    try t.expectEqualStrings("loose.txt", second.items[0].path);
}

test "vcs module name is backend neutral" {
    const t = std.testing;
    try t.expectEqualStrings("vcs", module_name_for_test);
}

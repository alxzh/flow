const std = @import("std");
const tp = @import("thespian");
const shell = @import("shell");
const bin_path = @import("bin_path");
const root = @import("soft_root").root;

pub const Error = error{ OutOfMemory, HgNotFound, HgCallFailed, WriteFailed };

const log_execute = false;

/// Actor message namespace. Backend-neutral so Project only ever sees "vcs".
pub const module_name = "vcs";
const hg_binary_name = "hg";

pub fn workspace_path(context_: usize, cwd: []const u8) Error!void {
    const fn_name = @src().fn_name;
    try hg(context_, cwd, .{"root"}, struct {
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

/// Sends the worktree root and metadata directory twice (there is no separate
/// common directory), then the exit code.
pub fn discover(context_: usize, cwd: []const u8) Error!void {
    const tag = @src().fn_name;
    try hg(context_, cwd, .{"root"}, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |value| {
                const root_dir = std.mem.trim(u8, value, " \t\r");
                if (root_dir.len == 0) continue;
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const metadata_dir = std.fmt.bufPrint(&path_buf, "{s}{c}.hg", .{ root_dir, std.fs.path.sep }) catch return;
                parent.send(.{ module_name, context, tag, root_dir }) catch return;
                parent.send(.{ module_name, context, tag, metadata_dir }) catch return;
                parent.send(.{ module_name, context, tag, metadata_dir }) catch return;
                return;
            }
        }
    }.result, exit_result(tag));
}

pub const workspace_files_tag = "workspace_files";
const tracked_files_tag = "workspace_files_tracked";
const unknown_files_tag = "workspace_files_unknown";

const FilesPending = struct {
    tracked_done: bool = false,
    unknown_done: bool = false,
    failed: bool = false,
};

/// Listings in progress, by the caller's context. File finders list their
/// projects on their own actors, so this is reached from several threads and
/// the mutex guards the map. Each listing is only touched by the actor that
/// started it, which gets the replies of its commands.
var files_pendings: std.AutoHashMapUnmanaged(usize, *FilesPending) = .empty;
var files_pendings_mutex: std.Io.Mutex = .init;

fn files_pending(context: usize) ?*FilesPending {
    const io = root.get_io();
    files_pendings_mutex.lockUncancelable(io);
    defer files_pendings_mutex.unlock(io);
    return files_pendings.get(context);
}

fn add_files_pending(context: usize, pending: *FilesPending) Error!void {
    const io = root.get_io();
    files_pendings_mutex.lockUncancelable(io);
    defer files_pendings_mutex.unlock(io);
    if (files_pendings.contains(context)) return error.HgCallFailed;
    files_pendings.put(allocator, context, pending) catch return error.OutOfMemory;
}

fn remove_files_pending(context: usize) void {
    const io = root.get_io();
    files_pendings_mutex.lockUncancelable(io);
    defer files_pendings_mutex.unlock(io);
    _ = files_pendings.remove(context);
}

pub fn cancel_workspace_files(context: usize) void {
    const io = root.get_io();
    files_pendings_mutex.lockUncancelable(io);
    defer files_pendings_mutex.unlock(io);
    if (files_pendings.fetchRemove(context)) |kv| allocator.destroy(kv.value);
}

/// Enumerate indexed workspace files: tracked files via `hg files` (manifest
/// based, no clean/all working-copy scan) plus unknown files via
/// `hg status -u`, both scoped to the explicit project cwd (`.`), bare
/// NUL-delimited paths. Removed entries never appear (`files` excludes them
/// and the unknown phase selects only `?`); ignored files are excluded by
/// default. Values stream under `workspace_files_tag`; the terminal null and
/// aggregate exit status are sent only after both phases finish.
pub fn workspace_files(context: usize, cwd: []const u8) Error!void {
    const pending = allocator.create(FilesPending) catch return error.OutOfMemory;
    pending.* = .{};
    add_files_pending(context, pending) catch |e| {
        allocator.destroy(pending);
        return e;
    };
    errdefer {
        remove_files_pending(context);
        allocator.destroy(pending);
    }
    try hg_with_tag_delimited(context, cwd, tracked_files_tag, .{ "files", "-0", "--", "." }, struct {
        fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, ctx, tracked_files_tag, output }) catch {};
        }
    }.result, exit_null_status(tracked_files_tag), 0);
    hg_with_tag_delimited(context, cwd, unknown_files_tag, .{ "status", "-u", "-n", "-0", "--", "." }, struct {
        fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, ctx, unknown_files_tag, output }) catch {};
        }
    }.result, exit_null_status(unknown_files_tag), 0) catch {
        // The tracked-file command is already in flight. Let its terminator
        // produce the single public completion after marking this phase done.
        pending.unknown_done = true;
        pending.failed = true;
    };
}

pub fn workspace_deleted_files(context: usize, cwd: []const u8) Error!void {
    const tag = @src().fn_name;
    return hg_with_tag_delimited(context, cwd, tag, .{ "status", "-d", "-r", "-n", "-0", "--", "." }, struct {
        fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
            var it = std.mem.splitScalar(u8, output, 0);
            while (it.next()) |path| if (path.len > 0)
                parent.send(.{ module_name, ctx, tag, path }) catch return;
        }
    }.result, exit_null_status(tag), 0);
}

/// Forward bare NUL-delimited paths under the terminal workspace_files tag.
pub fn handle_tracked_files(context: usize, output: []const u8) void {
    if (files_pending(context) == null) return;
    forwardBarePaths(context, output);
}

/// Forward bare NUL-delimited unknown paths under the terminal tag.
pub fn handle_unknown_files(context: usize, output: []const u8) void {
    if (files_pending(context) == null) return;
    forwardBarePaths(context, output);
}

fn forwardBarePaths(context: usize, output: []const u8) void {
    var it = std.mem.splitScalar(u8, output, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const path = if (entry[entry.len - 1] == '\r') entry[0 .. entry.len - 1] else entry;
        if (path.len == 0) continue;
        tp.self_pid().send(.{ module_name, context, workspace_files_tag, path }) catch return;
    }
}

pub fn finish_tracked_files(context: usize, status_code: i64) void {
    finishFilesPhase(context, .tracked, status_code);
}

pub fn finish_unknown_files(context: usize, status_code: i64) void {
    finishFilesPhase(context, .unknown, status_code);
}

const FilesPhase = enum { tracked, unknown };

fn finishFilesPhase(context: usize, phase: FilesPhase, status_code: i64) void {
    const pending = files_pending(context) orelse return;
    switch (phase) {
        .tracked => pending.tracked_done = true,
        .unknown => pending.unknown_done = true,
    }
    pending.failed = pending.failed or status_code != 0;
    if (!pending.tracked_done or !pending.unknown_done) return;
    remove_files_pending(context);
    const aggregate_exit_code: i64 = if (pending.failed) 1 else 0;
    allocator.destroy(pending);
    tp.self_pid().send(.{ module_name, context, workspace_files_tag, null, aggregate_exit_code }) catch {};
}

/// Route tracked-phase chunks vs terminator from the facade.
pub fn handle_tracked_files_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    var status_code: i64 = 0;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_tracked_files(context, output);
        return;
    }
    if (m.match(.{ tp.any, tp.any, tp.any, tp.null_, tp.extract(&status_code) }) catch false) {
        finish_tracked_files(context, status_code);
        return;
    }
}

/// Route unknown-phase chunks vs terminator from the facade.
pub fn handle_unknown_files_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    var status_code: i64 = 0;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_unknown_files(context, output);
        return;
    }
    if (m.match(.{ tp.any, tp.any, tp.any, tp.null_, tp.extract(&status_code) }) catch false) {
        finish_unknown_files(context, status_code);
        return;
    }
}

const status_tag = "status";
const status_files_tag = "status_files";
const status_shelves_tag = "status_shelves";
const status_branch_tag = "status_branch";

const StatusPending = struct {
    files_done: bool = false,
    shelves_done: bool = false,
    branch_done: bool = false,
    shelves: usize = 0,
};

/// Only the project manager's actor uses this, so it needs no lock.
var status_pendings: std.AutoHashMapUnmanaged(usize, *StatusPending) = .empty;

/// Report working-copy status and map Mercurial shelves to Flow's existing
/// stash count. Mercurial has no portable upstream ahead/behind equivalent,
/// so those fields intentionally remain unset.
pub fn status(context: usize, cwd: []const u8) Error!void {
    if (status_pendings.contains(context)) return error.HgCallFailed;
    const pending = allocator.create(StatusPending) catch return error.OutOfMemory;
    pending.* = .{};
    status_pendings.put(allocator, context, pending) catch {
        allocator.destroy(pending);
        return error.OutOfMemory;
    };
    errdefer {
        _ = status_pendings.remove(context);
        allocator.destroy(pending);
    }

    try hg_with_tag_delimited(context, cwd, status_files_tag, .{
        "status", "-m", "-a", "-r", "-d", "-u", "-0",
    }, struct {
        fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, ctx, status_files_tag, output }) catch {};
        }
    }.result, exit_null(status_files_tag), 0);

    hg_with_tag(context, cwd, status_shelves_tag, .{
        "shelve", "--list",
    }, struct {
        fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, ctx, status_shelves_tag, output }) catch {};
        }
    }.result, exit_null(status_shelves_tag)) catch {
        // Shelving is an optional extension in some Mercurial installations.
        // A missing command simply means no stash-equivalent count.
        pending.shelves_done = true;
    };

    hg_with_tag(context, cwd, status_branch_tag, .{ "log", "-r", ".", "--template", "{if(activebookmark, activebookmark, branch)}\n" }, struct {
        fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, ctx, status_branch_tag, output }) catch {};
        }
    }.result, exit_null(status_branch_tag)) catch {
        pending.branch_done = true;
    };
}

pub fn handle_status_files(context: usize, output: []const u8) void {
    if (status_pendings.get(context) == null) return;
    var it = std.mem.splitScalar(u8, output, 0);
    while (it.next()) |entry| {
        const parsed = parseHgStatusEntry(entry) orelse continue;
        const xy: []const u8 = switch (parsed.kind) {
            'M' => ".M",
            'A' => ".A",
            'R', '!' => ".D",
            '?' => {
                tp.self_pid().send(.{ module_name, context, status_tag, "?", parsed.path }) catch {};
                continue;
            },
            else => continue,
        };
        tp.self_pid().send(.{ module_name, context, status_tag, "1", xy, "N...", "", "", "", "", "", parsed.path }) catch {};
    }
}

pub fn handle_status_shelves(context: usize, output: []const u8) void {
    const pending = status_pendings.get(context) orelse return;
    pending.shelves += countNonEmptyLines(output);
}

pub fn handle_status_branch(context: usize, output: []const u8) void {
    if (status_pendings.get(context) == null) return;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const branch = std.mem.trim(u8, line, " \t\r");
        if (branch.len == 0) continue;
        tp.self_pid().send(.{ module_name, context, status_tag, "#", "branch.head", branch }) catch {};
        return;
    }
}

pub fn countNonEmptyLines(output: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count;
}

const StatusPhase = enum { files, shelves, branch };

fn finishStatusPhase(context: usize, phase: StatusPhase) void {
    const pending = status_pendings.get(context) orelse return;
    switch (phase) {
        .files => pending.files_done = true,
        .shelves => pending.shelves_done = true,
        .branch => pending.branch_done = true,
    }
    if (!pending.files_done or !pending.shelves_done or !pending.branch_done) return;
    _ = status_pendings.remove(context);
    defer allocator.destroy(pending);
    if (pending.shelves > 0) {
        var count_buf: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{pending.shelves}) catch "";
        if (count.len > 0)
            tp.self_pid().send(.{ module_name, context, status_tag, "#", "stash", count }) catch {};
    }
    tp.self_pid().send(.{ module_name, context, status_tag, null }) catch {};
}

pub fn handle_status_files_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_status_files(context, output);
    } else if (m.match(.{ tp.any, tp.any, tp.any, tp.null_ }) catch false) {
        finishStatusPhase(context, .files);
    }
}

pub fn handle_status_shelves_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_status_shelves(context, output);
    } else if (m.match(.{ tp.any, tp.any, tp.any, tp.null_ }) catch false) {
        finishStatusPhase(context, .shelves);
    }
}

pub fn handle_status_branch_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_status_branch(context, output);
    } else if (m.match(.{ tp.any, tp.any, tp.any, tp.null_ }) catch false) {
        finishStatusPhase(context, .branch);
    }
}

pub fn file_id(context_: usize, cwd: []const u8, file_path: []const u8) Error!void {
    _ = file_path;
    const tag = "file_id";
    // Working-copy baseline is the first parent. Fails on empty repos.
    try hg(context_, cwd, .{ "log", "-r", "p1()", "--template", "{node}\n" }, struct {
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
    const tag = "file_content";
    const rev = if (file_id_.len > 0) file_id_ else "p1()";
    try hg_raw(context_, cwd, .{ "cat", "-r", rev, "--", relative_to(cwd, file_path) }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, tag, output }) catch {};
        }
    }.result, exit_null(tag));
}

// --- blame (two-phase async: annotate nodes, then log metadata) ---

const blame_nodes_tag = "blame_nodes";
const blame_meta_tag = "blame_meta";
/// Unit-separator field delimiter for the log template (argv-safe, NUL-free).
const blame_field_sep: u8 = 0x1f;

const BlamePending = struct {
    cwd: []const u8,
    nodes_text: std.ArrayListUnmanaged(u8) = .empty,
    meta_text: std.ArrayListUnmanaged(u8) = .empty,
    nodes: std.ArrayListUnmanaged([40]u8) = .empty,
    meta_batches_pending: usize = 0,
};

/// Only the project manager's actor uses this, so it needs no lock.
var blame_pendings: std.AutoHashMapUnmanaged(usize, *BlamePending) = .empty;

fn blamePending(_: std.mem.Allocator, context: usize) ?*BlamePending {
    return blame_pendings.get(context);
}

pub fn blame(context_: usize, cwd: []const u8, file_path: []const u8) Error!void {
    if (blame_pendings.contains(context_)) return error.HgCallFailed;
    const cwd_copy = allocator.dupe(u8, cwd) catch return error.OutOfMemory;
    errdefer allocator.free(cwd_copy);
    const pending = allocator.create(BlamePending) catch return error.OutOfMemory;
    errdefer allocator.destroy(pending);
    pending.* = .{ .cwd = cwd_copy };
    try blame_pendings.put(allocator, context_, pending);
    errdefer _ = blame_pendings.remove(context_);

    // One node hash per line, in file order.
    try hg_with_tag(context_, cwd, blame_nodes_tag, .{
        "annotate", "--template", "{lines % \"{node}\\n\"}", "--", file_path,
    }, struct {
        fn result(context: usize, parent: tp.pid_ref, output: []const u8) void {
            parent.send(.{ module_name, context, blame_nodes_tag, output }) catch {};
        }
    }.result, exit_code(blame_nodes_tag));
}

/// Accumulate annotate output chunks. Called from project_manager.
pub fn handle_blame_nodes(context: usize, output: []const u8) void {
    const pending = blamePending(allocator, context) orelse return;
    pending.nodes_text.appendSlice(allocator, output) catch {};
}

/// Annotate finished; start the metadata lookup or terminate with null.
pub fn finish_blame_nodes(context: usize, exit_status: i64) void {
    const pending = blamePending(allocator, context) orelse return;
    if (exit_status != 0) {
        sendBlameNull(context);
        freeBlamePending(context);
        return;
    }
    parseBlameNodes(pending) catch {
        sendBlameNull(context);
        freeBlamePending(context);
        return;
    };
    if (pending.nodes.items.len == 0) {
        sendBlameNull(context);
        freeBlamePending(context);
        return;
    }
    // Unique revisions for metadata lookups, preserving first-seen order.
    // A hash set keeps this work linear even for files with long histories.
    var seen: std.AutoHashMapUnmanaged([40]u8, void) = .empty;
    defer seen.deinit(allocator);
    var unique: std.ArrayListUnmanaged([40]u8) = .empty;
    defer unique.deinit(allocator);
    for (pending.nodes.items) |node| {
        const gop = seen.getOrPut(allocator, node) catch {
            sendBlameNull(context);
            freeBlamePending(context);
            return;
        };
        if (gop.found_existing) continue;
        gop.value_ptr.* = {};
        unique.append(allocator, node) catch {
            sendBlameNull(context);
            freeBlamePending(context);
            return;
        };
    }

    // Bound each argv well below typical ARG_MAX limits. Batches run
    // asynchronously; metadata records are newline framed, so their output
    // can safely interleave in meta_text.
    const revisions_per_batch = 256;
    var begin: usize = 0;
    while (begin < unique.items.len) {
        const end = @min(begin + revisions_per_batch, unique.items.len);
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(allocator);
        argv.append(allocator, "log") catch {
            sendBlameNull(context);
            freeBlamePending(context);
            return;
        };
        for (unique.items[begin..end]) |*node|
            argv.appendSlice(allocator, &.{ "-r", node }) catch {
                sendBlameNull(context);
                freeBlamePending(context);
                return;
            };
        argv.appendSlice(allocator, &.{ "--template", blameLogTemplate() }) catch {
            sendBlameNull(context);
            freeBlamePending(context);
            return;
        };
        hg_argv_with_tag(context, pending.cwd, blame_meta_tag, argv.items, struct {
            fn result(ctx: usize, parent: tp.pid_ref, output: []const u8) void {
                parent.send(.{ module_name, ctx, blame_meta_tag, output }) catch {};
            }
        }.result, exit_code(blame_meta_tag)) catch {
            begin = end;
            continue;
        };
        pending.meta_batches_pending += 1;
        begin = end;
    }
    if (pending.meta_batches_pending == 0) {
        sendBlameNull(context);
        freeBlamePending(context);
    }
}

fn blameLogTemplate() []const u8 {
    // {node}<US>{person}<US>{email}<US>{hgdate}<US>{firstline}\n
    return "{node}\x1f{author|person}\x1f{author|email}\x1f{date|hgdate}\x1f{desc|firstline}\n";
}

fn parseBlameNodes(pending: *BlamePending) error{OutOfMemory}!void {
    var it = std.mem.splitScalar(u8, pending.nodes_text.items, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed.len != 40) continue;
        var node: [40]u8 = undefined;
        @memcpy(&node, trimmed[0..40]);
        // Validate hex.
        for (node) |c| switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => break,
        } else {
            try pending.nodes.append(allocator, node);
            continue;
        }
        // Non-hex line: skip (avoids poisoning blame with warnings).
        continue;
    }
}

/// Route annotate chunks vs terminator from project_manager.
pub fn handle_blame_nodes_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    var status_: i64 = undefined;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_blame_nodes(context, output);
        return;
    }
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&status_) }) catch false) {
        finish_blame_nodes(context, status_);
        return;
    }
}

/// Route log metadata chunks vs terminator from project_manager.
pub fn handle_blame_meta_routed(context: usize, m: tp.message) void {
    var output: []const u8 = undefined;
    var status_: i64 = undefined;
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&output) }) catch false) {
        handle_blame_meta(context, output);
        return;
    }
    if (m.match(.{ tp.any, tp.any, tp.any, tp.extract(&status_) }) catch false) {
        finish_blame_meta(context, status_);
        return;
    }
}

/// Accumulate log metadata chunks. Called from project_manager.
pub fn handle_blame_meta(context: usize, output: []const u8) void {
    const pending = blamePending(allocator, context) orelse return;
    pending.meta_text.appendSlice(allocator, output) catch {};
}

/// Log finished; emit incremental blame and terminate with null.
pub fn finish_blame_meta(context: usize, exit_status: i64) void {
    const pending = blamePending(allocator, context) orelse return;
    if (pending.meta_batches_pending == 0) return;
    pending.meta_batches_pending -= 1;
    if (pending.meta_batches_pending > 0) return;
    defer freeBlamePending(context);

    // A failed batch leaves those lines with unknown metadata, while records
    // from successful batches remain useful.
    _ = exit_status;
    var by_node: std.StringHashMapUnmanaged(BlameMeta) = .empty;
    defer {
        var it = by_node.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.author);
            allocator.free(kv.value_ptr.email);
            allocator.free(kv.value_ptr.summary);
            allocator.free(kv.value_ptr.path);
        }
        by_node.deinit(allocator);
    }
    parseBlameMeta(allocator, pending.meta_text.items, &by_node) catch {
        sendBlameNull(context);
        return;
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (pending.nodes.items, 0..) |node, i| {
        const meta = by_node.get(&node);
        const lineno = i + 1;
        out.writer.print("{s} 1 {d} 1\n", .{ node, lineno }) catch {
            sendBlameNull(context);
            return;
        };
        if (meta) |m| {
            out.writer.print("author {s}\nauthor-mail <{s}>\nauthor-time {d}\nauthor-tz {d}\nsummary {s}\nfilename {s}\n", .{
                m.author, m.email, m.time, m.tz_hhmm, m.summary, m.path,
            }) catch {
                sendBlameNull(context);
                return;
            };
        } else {
            out.writer.print("author unknown\nauthor-mail <>\nauthor-time 0\nauthor-tz 0\nsummary \nfilename \n", .{}) catch {
                sendBlameNull(context);
                return;
            };
        }
    }
    sendBlameChunks(context, out.written());
    sendBlameNull(context);
}

const BlameMeta = struct {
    author: []const u8,
    email: []const u8,
    time: i64,
    tz_hhmm: i16,
    summary: []const u8,
    path: []const u8,
};

fn parseBlameMeta(allocator_: std.mem.Allocator, text: []const u8, out: *std.StringHashMapUnmanaged(BlameMeta)) error{OutOfMemory}!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, blame_field_sep);
        const node = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const email = fields.next() orelse continue;
        const hgdate = fields.next() orelse continue;
        const summary = fields.next() orelse "";
        if (node.len != 40) continue;
        var date_it = std.mem.splitScalar(u8, hgdate, ' ');
        const time_s = date_it.next() orelse "0";
        const tz_s = date_it.next() orelse "0";
        const time = std.fmt.parseInt(i64, std.mem.trim(u8, time_s, " \t\r"), 10) catch 0;
        const tz_sec = std.fmt.parseInt(i32, std.mem.trim(u8, tz_s, " \t\r"), 10) catch 0;
        // Requests are deduplicated, so duplicates carry no new
        // information. Skipping before allocating anything keeps the map
        // consistent and avoids leaking on existing keys or partial
        // value allocation.
        if (out.contains(node)) continue;
        const author_d = allocator_.dupe(u8, author) catch return error.OutOfMemory;
        const email_d = allocator_.dupe(u8, email) catch {
            allocator_.free(author_d);
            return error.OutOfMemory;
        };
        const summary_d = allocator_.dupe(u8, summary) catch {
            allocator_.free(email_d);
            allocator_.free(author_d);
            return error.OutOfMemory;
        };
        const key_d = allocator_.dupe(u8, node) catch {
            allocator_.free(summary_d);
            allocator_.free(email_d);
            allocator_.free(author_d);
            return error.OutOfMemory;
        };
        const path_d = allocator_.dupe(u8, "") catch {
            allocator_.free(key_d);
            allocator_.free(summary_d);
            allocator_.free(email_d);
            allocator_.free(author_d);
            return error.OutOfMemory;
        };
        out.put(allocator_, key_d, .{
            .author = author_d,
            .email = email_d,
            .time = time,
            .tz_hhmm = tzSecondsToHhmm(tz_sec),
            .summary = summary_d,
            .path = path_d,
        }) catch {
            allocator_.free(path_d);
            allocator_.free(key_d);
            allocator_.free(summary_d);
            allocator_.free(email_d);
            allocator_.free(author_d);
            return error.OutOfMemory;
        };
    }
}

/// Convert an hgdate timezone offset (seconds WEST of UTC, opposite of
/// Git `%z`) to git-style ±HHMM as parsed by `VcsBlame` (e.g. hg `25200`,
/// UTC-7, becomes `-700` for `-0700`).
pub fn tzSecondsToHhmm(tz_sec_west: i32) i16 {
    const east: i32 = 0 -| tz_sec_west;
    const neg = east < 0;
    const abs: i32 = if (neg) 0 -| east else east;
    const hours: i32 = @divTrunc(abs, 3600);
    const mins: i32 = @divTrunc(@mod(abs, 3600), 60);
    const hhmm: i32 = hours * 100 + mins;
    const signed: i32 = if (neg) 0 - hhmm else hhmm;
    return @intCast(@max(std.math.minInt(i16), @min(std.math.maxInt(i16), signed)));
}

fn sendBlameChunks(context: usize, text: []const u8) void {
    // Keep messages well under tp.max_message_size.
    const max_chunk = 32 * 1024;
    var start: usize = 0;
    while (start < text.len) {
        var end = @min(start + max_chunk, text.len);
        // Split on line boundaries when possible.
        if (end < text.len) {
            if (std.mem.lastIndexOfScalar(u8, text[start..end], '\n')) |pos| {
                end = start + pos + 1;
            }
        }
        if (end <= start) end = @min(start + max_chunk, text.len);
        tp.self_pid().send(.{ module_name, context, "blame", text[start..end] }) catch return;
        start = end;
    }
}

fn sendBlameNull(context: usize) void {
    tp.self_pid().send(.{ module_name, context, "blame", null }) catch {};
}

fn freeBlamePending(context: usize) void {
    if (blame_pendings.fetchRemove(context)) |kv| {
        const pending = kv.value;
        allocator.free(pending.cwd);
        pending.nodes_text.deinit(allocator);
        pending.meta_text.deinit(allocator);
        pending.nodes.deinit(allocator);
        allocator.destroy(pending);
    }
}

// --- pure parsing helpers (unit-tested) ---

pub const HgEntry = struct {
    kind: u8,
    path: []const u8,
};

/// Parse one NUL-separated `hg status` entry ("X path").
pub fn parseHgStatusEntry(entry: []const u8) ?HgEntry {
    if (entry.len < 3 or entry[1] != ' ') return null;
    const kind = entry[0];
    const path = entry[2..];
    // Strip stray carriage returns from Windows shells.
    const clean = if (path.len > 0 and path[path.len - 1] == '\r') path[0 .. path.len - 1] else path;
    return .{ .kind = kind, .path = clean };
}

// --- plumbing ---

fn hg(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return hg_err(context, cwd, cmd, out, noop, exit);
}

fn hg_raw(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return hg_err_with_tag_options(context, cwd, @src().fn_name, cmd, out, noop, exit, false, '\n');
}

fn hg_with_tag(
    context: usize,
    cwd: []const u8,
    comptime tag: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return hg_err_with_tag(context, cwd, tag, cmd, out, noop, exit);
}

fn hg_with_tag_delimited(
    context: usize,
    cwd: []const u8,
    comptime tag: []const u8,
    cmd: anytype,
    out: OutputHandler,
    exit: ExitHandler,
    delimiter: u8,
) Error!void {
    return hg_err_with_tag_options(context, cwd, tag, cmd, out, noop, exit, true, delimiter);
}

fn hg_err(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return hg_err_with_tag(context, cwd, @src().fn_name, cmd, out, err, exit);
}

fn hg_err_delimited(
    context: usize,
    cwd: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
    delimiter: u8,
) Error!void {
    return hg_err_with_tag_options(context, cwd, @src().fn_name, cmd, out, err, exit, true, delimiter);
}

fn hg_err_with_tag(
    context: usize,
    cwd: []const u8,
    comptime tag: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
) Error!void {
    return hg_err_with_tag_options(context, cwd, tag, cmd, out, err, exit, true, '\n');
}

fn hg_err_with_tag_options(
    context: usize,
    cwd: []const u8,
    comptime tag: []const u8,
    cmd: anytype,
    out: OutputHandler,
    err: OutputHandler,
    exit: ExitHandler,
    line_buffered: bool,
    stdout_delimiter: u8,
) Error!void {
    _ = tag;
    const cbor = @import("cbor");
    const hg_binary = get_hg() orelse return error.HgNotFound;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const writer = &buf.writer;
    switch (@typeInfo(@TypeOf(cmd))) {
        .@"struct" => |info| if (info.is_tuple) {
            // hg --cwd <cwd> <cmd...>
            try cbor.writeArrayHeader(writer, info.field_names.len + 3);
            try cbor.writeValue(writer, hg_binary);
            try cbor.writeValue(writer, "--cwd");
            try cbor.writeValue(writer, cwd);
            inline for (info.field_names) |name|
                try cbor.writeValue(writer, @field(cmd, name));
            return shell.execute(allocator, .{ .buf = buf.written() }, .{
                .context = context,
                .out = to_shell_output_handler(out),
                .err = to_shell_output_handler(err),
                .exit = exit,
                .log_execute = log_execute,
                .line_buffered = line_buffered,
                .stdout_delimiter = stdout_delimiter,
            }) catch error.HgCallFailed;
        },
        else => {},
    }
    @compileError("hg command should be a tuple: " ++ @typeName(@TypeOf(cmd)));
}

fn hg_argv_with_tag(
    context: usize,
    cwd: []const u8,
    comptime tag: []const u8,
    argv_cmd: []const []const u8,
    out: OutputHandler,
    exit: ExitHandler,
) Error!void {
    _ = tag;
    const cbor = @import("cbor");
    const hg_binary = get_hg() orelse return error.HgNotFound;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    try cbor.writeArrayHeader(writer, argv_cmd.len + 3);
    try cbor.writeValue(writer, hg_binary);
    try cbor.writeValue(writer, "--cwd");
    try cbor.writeValue(writer, cwd);
    for (argv_cmd) |arg| try cbor.writeValue(writer, arg);
    return shell.execute(allocator, .{ .buf = buf.written() }, .{
        .context = context,
        .out = to_shell_output_handler(out),
        .err = to_shell_output_handler(log_err),
        .exit = exit,
        .log_execute = log_execute,
    }) catch error.HgCallFailed;
}

fn exit_null(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, _: i64) void {
            parent.send(.{ module_name, context, tag, null }) catch {};
        }
    }.exit;
}

fn exit_null_status(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, status_code: i64) void {
            parent.send(.{ module_name, context, tag, null, status_code }) catch {};
        }
    }.exit;
}

fn exit_null_on_error(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code_: i64) void {
            if (exit_code_ != 0)
                parent.send(.{ module_name, context, tag, null }) catch {};
        }
    }.exit;
}

fn exit_code(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code_: i64) void {
            parent.send(.{ module_name, context, tag, exit_code_ }) catch {};
        }
    }.exit;
}

fn exit_result(comptime tag: []const u8) shell.ExitHandler {
    return struct {
        fn exit(context: usize, parent: tp.pid_ref, _: []const u8, _: []const u8, exit_code_: i64) void {
            parent.send(.{ module_name, context, tag, exit_code_ }) catch {};
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

fn relative_to(cwd: []const u8, file_path: []const u8) []const u8 {
    if (file_path.len <= cwd.len or !std.mem.startsWith(u8, file_path, cwd)) return file_path;
    if (!std.fs.path.isSep(file_path[cwd.len])) return file_path;
    return file_path[cwd.len + 1 ..];
}

fn log_err(_: usize, _: tp.pid_ref, output: []const u8) void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| if (line.len > 0)
        std.log.err("{s}: {s}", .{ module_name, line });
}

fn noop(_: usize, _: tp.pid_ref, _: []const u8) void {}

/// The Mercurial or Sapling binary, found on first use. File finders run it
/// on their own threads, so the lookup is serialized.
var hg_path: ?struct {
    path: ?[:0]const u8 = null,
} = null;
var hg_path_mutex: std.Io.Mutex = .init;

const allocator = std.heap.c_allocator;

fn get_hg() ?[]const u8 {
    const io = root.get_io();
    hg_path_mutex.lockUncancelable(io);
    defer hg_path_mutex.unlock(io);
    if (hg_path) |p| return p.path;
    const path = (bin_path.find_binary_in_path(allocator, hg_binary_name) catch null) orelse
        (bin_path.find_binary_in_path(allocator, "sl") catch null);
    hg_path = .{ .path = path };
    return path;
}

test "parseHgStatusEntry splits kind and path" {
    const t = std.testing;
    const e = parseHgStatusEntry("M src/foo.zig").?;
    try t.expectEqual(@as(u8, 'M'), e.kind);
    try t.expectEqualStrings("src/foo.zig", e.path);
    const q = parseHgStatusEntry("? path with spaces.txt").?;
    try t.expectEqual(@as(u8, '?'), q.kind);
    try t.expectEqualStrings("path with spaces.txt", q.path);
    try t.expect(parseHgStatusEntry("") == null);
    try t.expect(parseHgStatusEntry("M") == null);
}

test "countNonEmptyLines counts shelves" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), countNonEmptyLines(""));
    try t.expectEqual(@as(usize, 2), countNonEmptyLines("one  description\ntwo  description\n"));
    try t.expectEqual(@as(usize, 2), countNonEmptyLines("one\n\n two\r\n"));
}

test "tzSecondsToHhmm converts seconds-west offsets" {
    const t = std.testing;
    try t.expectEqual(@as(i16, 0), tzSecondsToHhmm(0));
    try t.expectEqual(@as(i16, -700), tzSecondsToHhmm(25200));
    try t.expectEqual(@as(i16, 700), tzSecondsToHhmm(-25200));
    try t.expectEqual(@as(i16, -530), tzSecondsToHhmm(19800));
    try t.expectEqual(@as(i16, 500), tzSecondsToHhmm(-18000));
}

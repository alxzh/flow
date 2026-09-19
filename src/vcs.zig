const std = @import("std");
const tp = @import("thespian");
const root = @import("soft_root").root;
const git = @import("git");
const mercurial = @import("mercurial");

pub const Error = error{ OutOfMemory, VcsNotFound, VcsCallFailed, WriteFailed };

pub const Backend = enum { git, mercurial };

/// Detect the nearest repository marker walking upward from the absolute
/// project directory. Checks `.git` (file or dir) and `.hg` (dir) at each
/// level. The nearest marker wins; when both markers exist in the same
/// directory, git wins deterministically. Returns null when no marker is
/// found or the path is not absolute.
pub fn detectBackend(project_dir: []const u8) ?Backend {
    if (project_dir.len == 0 or !std.fs.path.isAbsolute(project_dir)) return null;
    var dir: []const u8 = project_dir;
    // Strip trailing separators except root.
    while (dir.len > 1 and std.fs.path.isSep(dir[dir.len - 1])) : (dir = dir[0 .. dir.len - 1]) {}
    while (true) {
        if (hasMarker(dir, .git)) return .git;
        if (hasMarker(dir, .hg)) return .mercurial;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len >= dir.len) return null;
        // Reached filesystem root.
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
        if (dir.len == 0) return null;
    }
}

const Marker = enum { git, hg };

fn hasMarker(dir: []const u8, marker: Marker) bool {
    // Same-directory tie-break: git wins, so check git first in detectBackend.
    // Here just report presence.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const name: []const u8 = switch (marker) {
        .git => ".git",
        .hg => ".hg",
    };
    const full = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch return false;
    const io = root.get_io();
    const stat = std.Io.Dir.cwd().statFile(io, full, .{}) catch return false;
    return switch (marker) {
        // `.git` may be a worktree/submodule gitlink file or a directory.
        .git => stat.kind == .file or stat.kind == .directory or stat.kind == .sym_link,
        // `.hg` must be a directory.
        .hg => stat.kind == .directory or stat.kind == .sym_link,
    };
}

/// Split an absolute path into its ancestor directories from innermost to
/// root, purely (no filesystem access). Used for unit testing the
/// nearest-marker walk.
pub fn ancestorDirs(allocator: std.mem.Allocator, project_dir: []const u8) error{OutOfMemory}![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (project_dir.len == 0 or !std.fs.path.isAbsolute(project_dir)) return try list.toOwnedSlice(allocator);
    var dir: []const u8 = project_dir;
    while (dir.len > 1 and std.fs.path.isSep(dir[dir.len - 1])) : (dir = dir[0 .. dir.len - 1]) {}
    while (true) {
        try list.append(allocator, try allocator.dupe(u8, dir));
        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len >= dir.len) break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = parent;
        if (dir.len == 0) break;
    }
    return try list.toOwnedSlice(allocator);
}

/// Choose the nearest backend given the distance (index into ancestorDirs,
/// lower is nearer) of each marker. Pure helper for deterministic dispatch.
pub fn chooseBackend(git_distance: ?usize, hg_distance: ?usize) ?Backend {
    if (git_distance == null and hg_distance == null) return null;
    if (git_distance != null and hg_distance != null) {
        // Nearest wins; same-directory tie goes to git.
        if (git_distance.? <= hg_distance.?) return .git;
        return .mercurial;
    }
    if (git_distance != null) return .git;
    return .mercurial;
}

fn backendFor(cwd: []const u8) Error!Backend {
    return detectBackend(cwd) orelse return error.VcsNotFound;
}

pub fn workspace_path(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.workspace_path(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.workspace_path(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn current_branch(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.current_branch(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.current_branch(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn workspace_files(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.workspace_files(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.workspace_files(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn workspace_ignored_files(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.workspace_ignored_files(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.workspace_ignored_files(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn status(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.status(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.status(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn new_or_modified_files(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.new_or_modified_files(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.new_or_modified_files(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn file_id(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.file_id(context, cwd, file_path) catch |e| translateGitError(e),
        .mercurial => return mercurial.file_id(context, cwd, file_path) catch |e| translateHgError(e),
    }
}

pub fn file_content(context: usize, cwd: []const u8, file_path: []const u8, file_id_: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.file_content(context, cwd, file_path, file_id_) catch |e| translateGitError(e),
        .mercurial => return mercurial.file_content(context, cwd, file_path, file_id_) catch |e| translateHgError(e),
    }
}

pub fn check_ignore(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.check_ignore(context, cwd, file_path) catch |e| translateGitError(e),
        .mercurial => return mercurial.check_ignore(context, cwd, file_path) catch |e| translateHgError(e),
    }
}

pub fn blame(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.blame(context, cwd, file_path) catch |e| translateGitError(e),
        .mercurial => return mercurial.blame(context, cwd, file_path) catch |e| translateHgError(e),
    }
}

fn translateGitError(e: git.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.GitNotFound => error.VcsNotFound,
        error.GitCallFailed => error.VcsCallFailed,
        error.WriteFailed => error.WriteFailed,
    };
}

fn translateHgError(e: mercurial.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.HgNotFound => error.VcsNotFound,
        error.HgCallFailed => error.VcsCallFailed,
        error.WriteFailed => error.WriteFailed,
    };
}

/// Facade routing for Mercurial blame intermediates. Both backends stay
/// behind this module: project_manager only ever imports `vcs`.
pub fn handle_blame_nodes(context: usize, m: tp.message) void {
    mercurial.handle_blame_nodes_routed(context, m);
}

pub fn handle_blame_meta(context: usize, m: tp.message) void {
    mercurial.handle_blame_meta_routed(context, m);
}

/// Facade routing for Mercurial status phases.
pub fn handle_status_files(context: usize, m: tp.message) void {
    mercurial.handle_status_files_routed(context, m);
}

pub fn handle_status_shelves(context: usize, m: tp.message) void {
    mercurial.handle_status_shelves_routed(context, m);
}

/// Facade routing for Mercurial workspace enumeration phases.
pub fn handle_tracked_files(context: usize, m: tp.message) void {
    mercurial.handle_tracked_files_routed(context, m);
}

pub fn handle_unknown_files(context: usize, m: tp.message) void {
    mercurial.handle_unknown_files_routed(context, m);
}

/// Facade routing for the Mercurial ignore-query phases.
pub fn handle_ignore_output(context: usize, m: tp.message) void {
    mercurial.handle_ignore_output_routed(context, m);
}

pub fn handle_ignore_done(context: usize) void {
    mercurial.finish_ignore_check(context);
}

test "chooseBackend prefers nearest and git on ties" {
    const t = std.testing;
    try t.expectEqual(@as(?Backend, null), chooseBackend(null, null));
    try t.expectEqual(Backend.git, chooseBackend(0, null).?);
    try t.expectEqual(Backend.mercurial, chooseBackend(null, 0).?);
    try t.expectEqual(Backend.git, chooseBackend(1, 1).?);
    try t.expectEqual(Backend.git, chooseBackend(0, 2).?);
    try t.expectEqual(Backend.mercurial, chooseBackend(3, 1).?);
}

test "ancestorDirs walks innermost first" {
    const t = std.testing;
    const allocator = t.allocator;
    const dirs = try ancestorDirs(allocator, "/a/b/c");
    defer {
        for (dirs) |d| allocator.free(d);
        allocator.free(dirs);
    }
    try t.expectEqual(@as(usize, 4), dirs.len);
    try t.expectEqualStrings("/a/b/c", dirs[0]);
    try t.expectEqualStrings("/a/b", dirs[1]);
    try t.expectEqualStrings("/a", dirs[2]);
    try t.expectEqualStrings("/", dirs[3]);
}

test "detectBackend rejects relative paths" {
    const t = std.testing;
    try t.expect(detectBackend("") == null);
    try t.expect(detectBackend("a/b") == null);
    try t.expect(detectBackend("/definitely/not/a/repo/flow-test-xyz") == null);
}

test "detectBackend finds nearest markers in temp dirs" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    // Layout:
    //   repo/.hg                 (outer hg repo)
    //   repo/sub/.git/           (inner git repo shadows hg below sub/)
    //   mono/.git                (gitlink file, as in worktrees/submodules)
    //   mono/.hg/                (same-dir tie: git must win)
    //   plain/                   (no markers)
    try tmp.dir.createDirPath(io, "repo/sub/deep");
    try tmp.dir.createDirPath(io, "repo/.hg");
    try tmp.dir.createDirPath(io, "repo/sub/.git");
    try tmp.dir.createDirPath(io, "mono");
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/.git", .data = "gitdir: elsewhere" });
    try tmp.dir.createDirPath(io, "mono/.hg");
    try tmp.dir.createDirPath(io, "plain");

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(io, ".", &base_buf);
    const base = base_buf[0..base_len];

    var probe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const probe = struct {
        fn at(base_: []const u8, buf: *[std.Io.Dir.max_path_bytes]u8, rel: []const u8) []const u8 {
            const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ base_, rel }) catch unreachable;
            return full;
        }
    }.at;

    try t.expectEqual(Backend.git, detectBackend(probe(base, &probe_buf, "repo/sub/deep")).?);
    try t.expectEqual(Backend.git, detectBackend(probe(base, &probe_buf, "repo/sub")).?);
    try t.expectEqual(Backend.mercurial, detectBackend(probe(base, &probe_buf, "repo")).?);
    try t.expectEqual(Backend.git, detectBackend(probe(base, &probe_buf, "mono")).?);
    // `plain/` has no markers of its own; whatever the enclosing environment
    // provides above the temp root must resolve identically from the temp
    // root itself (this also holds when the checkout running the tests lives
    // inside a git repo, as tmp dirs are created under `.zig-cache/tmp`).
    try t.expectEqual(detectBackend(base), detectBackend(probe(base, &probe_buf, "plain")));
    // Trailing separators do not change the result.
    const with_slash = try std.fmt.bufPrint(&probe_buf, "{s}/repo/sub/deep/", .{base});
    try t.expectEqual(Backend.git, detectBackend(with_slash).?);
}

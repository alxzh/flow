const std = @import("std");
const tp = @import("thespian");
const root = @import("soft_root").root;
const git = @import("git");
const mercurial = @import("mercurial");

pub const Error = error{ OutOfMemory, VcsNotFound, VcsCallFailed, WriteFailed };

/// The first field of the messages that VCS commands send to their caller.
/// Every backend uses it, so that callers need not know which one runs.
pub const module_name = git.module_name;

comptime {
    std.debug.assert(std.mem.eql(u8, mercurial.module_name, module_name));
}

pub const Backend = enum { git, mercurial };
pub const DiffMode = git.DiffMode;
pub const IndexUpdate = git.IndexUpdate;

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

fn backendFor(cwd: []const u8) Error!Backend {
    return detectBackend(cwd) orelse return error.VcsNotFound;
}

pub fn workspace_path(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.workspace_path(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.workspace_path(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn discover(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.discover(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.discover(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn workspace_files(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.workspace_files(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.workspace_files(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn workspace_files_need_full_stat(cwd: []const u8) bool {
    return switch (backendFor(cwd) catch return false) {
        .git => git.workspace_files_need_full_stat(cwd),
        .mercurial => false,
    };
}

pub fn cancel_workspace_files(context: usize) void {
    mercurial.cancel_workspace_files(context);
}

pub fn workspace_deleted_files(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.workspace_deleted_files(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.workspace_deleted_files(context, cwd) catch |e| translateHgError(e),
    }
}

pub fn status(context: usize, cwd: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.status(context, cwd) catch |e| translateGitError(e),
        .mercurial => return mercurial.status(context, cwd) catch |e| translateHgError(e),
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

pub fn first_change(context: usize, cwd: []const u8, staged: bool, file_path: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.first_change(context, cwd, staged, file_path) catch |e| translateGitError(e),
        .mercurial => return error.VcsCallFailed,
    }
}

pub fn update_index(context: usize, cwd: []const u8, update: IndexUpdate, file_paths: []const []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.update_index(context, cwd, update, file_paths) catch |e| translateGitError(e),
        .mercurial => return error.VcsCallFailed,
    }
}

pub fn diff(context: usize, cwd: []const u8, mode: DiffMode, file_path: []const u8, orig_path: []const u8, context_lines: usize) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.diff(context, cwd, mode, file_path, orig_path, context_lines) catch |e| translateGitError(e),
        .mercurial => return error.VcsCallFailed,
    }
}

pub fn apply_patch(context: usize, cwd: []const u8, update: IndexUpdate, patch: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.apply_patch(context, cwd, update, patch) catch |e| translateGitError(e),
        .mercurial => return error.VcsCallFailed,
    }
}

/// File state queries back Project.request_vcs_file_state. They are not
/// implemented for Mercurial yet; failing makes the caller report the file as
/// unversioned, which only means that deleting it asks for confirmation.
pub fn ls_tree(context: usize, cwd: []const u8, rev: []const u8, file_path: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.ls_tree(context, cwd, rev, file_path) catch |e| translateGitError(e),
        .mercurial => return error.VcsCallFailed,
    }
}

pub fn file_status(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    switch (try backendFor(cwd)) {
        .git => return git.file_status(context, cwd, file_path) catch |e| translateGitError(e),
        .mercurial => return error.VcsCallFailed,
    }
}

pub fn blame(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    const owned_path = if (std.fs.path.isAbsolute(file_path)) null else std.fs.path.join(std.heap.c_allocator, &.{ cwd, file_path }) catch return error.OutOfMemory;
    defer if (owned_path) |path| std.heap.c_allocator.free(path);
    const path = owned_path orelse file_path;
    const dir = std.fs.path.dirname(path) orelse cwd;
    switch (try backendFor(dir)) {
        .git => return git.blame(context, path) catch |e| translateGitError(e),
        .mercurial => return mercurial.blame(context, dir, std.fs.path.basename(path)) catch |e| translateHgError(e),
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

pub fn handle_status_branch(context: usize, m: tp.message) void {
    mercurial.handle_status_branch_routed(context, m);
}

/// Facade routing for Mercurial workspace enumeration phases.
pub fn handle_tracked_files(context: usize, m: tp.message) void {
    mercurial.handle_tracked_files_routed(context, m);
}

pub fn handle_unknown_files(context: usize, m: tp.message) void {
    mercurial.handle_unknown_files_routed(context, m);
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

const std = @import("std");
const git = @import("git");

pub const Error = error{ OutOfMemory, VcsNotFound, VcsCallFailed, WriteFailed };
pub const module_name = git.module_name;
pub const DiffMode = git.DiffMode;
pub const IndexUpdate = git.IndexUpdate;

pub fn workspace_path(context: usize, cwd: []const u8) Error!void {
    return git.workspace_path(context, cwd) catch |e| translateGitError(e);
}

pub fn workspace_files(context: usize, cwd: []const u8) Error!void {
    return git.workspace_files(context, cwd) catch |e| translateGitError(e);
}

pub fn workspace_files_need_full_stat(cwd: []const u8) bool {
    return git.workspace_files_need_full_stat(cwd);
}

pub fn workspace_deleted_files(context: usize, cwd: []const u8) Error!void {
    return git.workspace_deleted_files(context, cwd) catch |e| translateGitError(e);
}

pub fn status(context: usize, cwd: []const u8) Error!void {
    return git.status(context, cwd) catch |e| translateGitError(e);
}

pub fn file_id(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    return git.file_id(context, cwd, file_path) catch |e| translateGitError(e);
}

pub fn discover(context: usize, cwd: []const u8) Error!void {
    return git.discover(context, cwd) catch |e| translateGitError(e);
}

pub fn file_content(context: usize, cwd: []const u8, file_path: []const u8, id: []const u8) Error!void {
    return git.file_content(context, cwd, file_path, id) catch |e| translateGitError(e);
}

pub fn ls_tree(context: usize, cwd: []const u8, rev: []const u8, file_path: []const u8) Error!void {
    return git.ls_tree(context, cwd, rev, file_path) catch |e| translateGitError(e);
}

pub fn file_status(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    return git.file_status(context, cwd, file_path) catch |e| translateGitError(e);
}

pub fn first_change(context: usize, cwd: []const u8, staged: bool, file_path: []const u8) Error!void {
    return git.first_change(context, cwd, staged, file_path) catch |e| translateGitError(e);
}

pub fn update_index(context: usize, cwd: []const u8, update: IndexUpdate, file_paths: []const []const u8) Error!void {
    return git.update_index(context, cwd, update, file_paths) catch |e| translateGitError(e);
}

pub fn diff(context: usize, cwd: []const u8, mode: DiffMode, file_path: []const u8, orig_path: []const u8, context_lines: usize) Error!void {
    return git.diff(context, cwd, mode, file_path, orig_path, context_lines) catch |e| translateGitError(e);
}

pub fn apply_patch(context: usize, cwd: []const u8, update: IndexUpdate, patch: []const u8) Error!void {
    return git.apply_patch(context, cwd, update, patch) catch |e| translateGitError(e);
}

pub fn blame(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    const owned_path = if (std.fs.path.isAbsolute(file_path)) null else std.fs.path.join(std.heap.c_allocator, &.{ cwd, file_path }) catch return error.OutOfMemory;
    defer if (owned_path) |path| std.heap.c_allocator.free(path);
    return git.blame(context, owned_path orelse file_path) catch |e| translateGitError(e);
}

fn translateGitError(e: git.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.GitNotFound => error.VcsNotFound,
        error.GitCallFailed => error.VcsCallFailed,
        error.WriteFailed => error.WriteFailed,
    };
}

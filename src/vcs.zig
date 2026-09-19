const git = @import("git");

pub const Error = error{ OutOfMemory, VcsNotFound, VcsCallFailed, WriteFailed };

pub fn workspace_path(context: usize, cwd: []const u8) Error!void {
    return git.workspace_path(context, cwd) catch |e| translateGitError(e);
}

pub fn current_branch(context: usize, cwd: []const u8) Error!void {
    return git.current_branch(context, cwd) catch |e| translateGitError(e);
}

pub fn workspace_files(context: usize, cwd: []const u8) Error!void {
    return git.workspace_files(context, cwd) catch |e| translateGitError(e);
}

pub fn workspace_ignored_files(context: usize, cwd: []const u8) Error!void {
    return git.workspace_ignored_files(context, cwd) catch |e| translateGitError(e);
}

pub fn status(context: usize, cwd: []const u8) Error!void {
    return git.status(context, cwd) catch |e| translateGitError(e);
}

pub fn new_or_modified_files(context: usize, cwd: []const u8) Error!void {
    return git.new_or_modified_files(context, cwd) catch |e| translateGitError(e);
}

pub fn file_id(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    return git.file_id(context, cwd, file_path) catch |e| translateGitError(e);
}

pub fn file_content(context: usize, cwd: []const u8, file_path: []const u8, file_id_: []const u8) Error!void {
    return git.file_content(context, cwd, file_path, file_id_) catch |e| translateGitError(e);
}

pub fn check_ignore(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    return git.check_ignore(context, cwd, file_path) catch |e| translateGitError(e);
}

pub fn blame(context: usize, cwd: []const u8, file_path: []const u8) Error!void {
    return git.blame(context, cwd, file_path) catch |e| translateGitError(e);
}

fn translateGitError(e: git.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.GitNotFound => error.VcsNotFound,
        error.GitCallFailed => error.VcsCallFailed,
        error.WriteFailed => error.WriteFailed,
    };
}

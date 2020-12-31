const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLiteExtendedIOError = error{
    SQLiteIOErrRead,
    SQLiteIOErrShortRead,
    SQLiteIOErrWrite,
    SQLiteIOErrFsync,
    SQLiteIOErrDirFsync,
    SQLiteIOErrTruncate,
    SQLiteIOErrFstat,
    SQLiteIOErrUnlock,
    SQLiteIOErrRDLock,
    SQLiteIOErrDelete,
    SQLiteIOErrBlocked,
    SQLiteIOErrNoMem,
    SQLiteIOErrAccess,
    SQLiteIOErrCheckReservedLock,
    SQLiteIOErrLock,
    SQLiteIOErrClose,
    SQLiteIOErrDirClose,
    SQLiteIOErrSHMOpen,
    SQLiteIOErrSHMSize,
    SQLiteIOErrSHMLock,
    SQLiteIOErrSHMMap,
    SQLiteIOErrSeek,
    SQLiteIOErrDeleteNoEnt,
    SQLiteIOErrMmap,
    SQLiteIOErrGetTempPath,
    SQLiteIOErrConvPath,
    SQLiteIOErrVnode,
    SQLiteIOErrAuth,
    SQLiteIOErrBeginAtomic,
    SQLiteIOErrCommitAtomic,
    SQLiteIOErrRollbackAtomic,
    SQLiteIOErrData,
    SQLiteIOErrCorruptFS,
};

pub const SQLiteExtendedCantOpenError = error{
    SQLiteCantOpenNoTempDir,
    SQLiteCantOpenIsDir,
    SQLiteCantOpenFullPath,
    SQLiteCantOpenConvPath,
    SQLiteCantOpenDirtyWAL,
    SQLiteCantOpenSymlink,
};

pub const SQLiteExtendedReadOnlyError = error{
    SQLiteReadOnlyRecovery,
    SQLiteReadOnlyCantLock,
    SQLiteReadOnlyRollback,
    SQLiteReadOnlyDBMoved,
    SQLiteReadOnlyCantInit,
    SQLiteReadOnlyDirectory,
};

pub const SQLiteExtendedConstraintError = error{
    SQLiteConstraintCheck,
    SQLiteConstraintCommitHook,
    SQLiteConstraintForeignKey,
    SQLiteConstraintFunction,
    SQLiteConstraintNotNull,
    SQLiteConstraintPrimaryKey,
    SQLiteConstraintTrigger,
    SQLiteConstraintUnique,
    SQLiteConstraintVTab,
    SQLiteConstraintRowID,
    SQLiteConstraintPinned,
};

pub const SQLiteExtendedError = error{
    SQLiteErrorMissingCollSeq,
    SQLiteErrorRetry,
    SQLiteErrorSnapshot,

    SQLiteLockedSharedCache,
    SQLiteLockedVTab,

    SQLiteBusyRecovery,
    SQLiteBusySnapshot,
    SQLiteBusyTimeout,

    SQLiteCorruptVTab,
    SQLiteCorruptSequence,
    SQLiteCorruptIndex,

    SQLiteAbortRollback,
};

pub const SQLiteError = error{
    SQLiteError,
    SQLiteInternal,
    SQLitePerm,
    SQLiteAbort,
    SQLiteBusy,
    SQLiteLocked,
    SQLiteNoMem,
    SQLiteReadOnly,
    SQLiteInterrupt,
    SQLiteIOErr,
    SQLiteCorrupt,
    SQLiteNotFound,
    SQLiteFull,
    SQLiteCantOpen,
    SQLiteProtocol,
    SQLiteEmpty,
    SQLiteSchema,
    SQLiteTooBig,
    SQLiteConstraint,
    SQLiteMismatch,
    SQLiteMisuse,
    SQLiteNoLFS,
    SQLiteAuth,
    SQLiteRange,
    SQLiteNotADatabase,
    SQLiteNotice,
    SQLiteWarning,
};

pub const Error = SQLiteError ||
    SQLiteExtendedError ||
    SQLiteExtendedIOError ||
    SQLiteExtendedCantOpenError ||
    SQLiteExtendedReadOnlyError ||
    SQLiteExtendedConstraintError;

pub fn errorFromResultCode(code: c_int) Error {
    // TODO(vincent): can we do something with comptime here ?
    // The version number is always static and defined by sqlite.

    // These errors are only available since 3.25.0.
    if (c.SQLITE_VERSION_NUMBER >= 3025000) {
        switch (code) {
            c.SQLITE_ERROR_SNAPSHOT => return error.SQLiteErrorSnapshot,
            c.SQLITE_LOCKED_VTAB => return error.SQLiteLockedVTab,
            c.SQLITE_CANTOPEN_DIRTYWAL => return error.SQLiteCantOpenDirtyWAL,
            c.SQLITE_CORRUPT_SEQUENCE => return error.SQLiteCorruptSequence,
            else => {},
        }
    }
    // These errors are only available since 3.31.0.
    if (c.SQLITE_VERSION_NUMBER >= 3031000) {
        switch (code) {
            c.SQLITE_CANTOPEN_SYMLINK => return error.SQLiteCantOpenSymlink,
            c.SQLITE_CONSTRAINT_PINNED => return error.SQLiteConstraintPinned,
            else => {},
        }
    }
    // These errors are only available since 3.32.0.
    if (c.SQLITE_VERSION_NUMBER >= 3032000) {
        switch (code) {
            c.SQLITE_IOERR_DATA => return error.SQLiteIOErrData, // See https://sqlite.org/cksumvfs.html
            c.SQLITE_BUSY_TIMEOUT => return error.SQLiteBusyTimeout,
            c.SQLITE_CORRUPT_INDEX => return error.SQLiteCorruptIndex,
            else => {},
        }
    }
    // These errors are only available since 3.34.0.
    if (c.SQLITE_VERSION_NUMBER >= 3034000) {
        switch (code) {
            c.SQLITE_IOERR_CORRUPTFS => return error.SQLiteIOErrCorruptFS,
            else => {},
        }
    }

    return switch (code) {
        c.SQLITE_ERROR => error.SQLiteError,
        c.SQLITE_INTERNAL => error.SQLiteInternal,
        c.SQLITE_PERM => error.SQLitePerm,
        c.SQLITE_ABORT => error.SQLiteAbort,
        c.SQLITE_BUSY => error.SQLiteBusy,
        c.SQLITE_LOCKED => error.SQLiteLocked,
        c.SQLITE_NOMEM => error.SQLiteNoMem,
        c.SQLITE_READONLY => error.SQLiteReadOnly,
        c.SQLITE_INTERRUPT => error.SQLiteInterrupt,
        c.SQLITE_IOERR => error.SQLiteIOErr,
        c.SQLITE_CORRUPT => error.SQLiteCorrupt,
        c.SQLITE_NOTFOUND => error.SQLiteNotFound,
        c.SQLITE_FULL => error.SQLiteFull,
        c.SQLITE_CANTOPEN => error.SQLiteCantOpen,
        c.SQLITE_PROTOCOL => error.SQLiteProtocol,
        c.SQLITE_EMPTY => error.SQLiteEmpty,
        c.SQLITE_SCHEMA => error.SQLiteSchema,
        c.SQLITE_TOOBIG => error.SQLiteTooBig,
        c.SQLITE_CONSTRAINT => error.SQLiteConstraint,
        c.SQLITE_MISMATCH => error.SQLiteMismatch,
        c.SQLITE_MISUSE => error.SQLiteMisuse,
        c.SQLITE_NOLFS => error.SQLiteNoLFS,
        c.SQLITE_AUTH => error.SQLiteAuth,
        c.SQLITE_RANGE => error.SQLiteRange,
        c.SQLITE_NOTADB => error.SQLiteNotADatabase,
        c.SQLITE_NOTICE => error.SQLiteNotice,
        c.SQLITE_WARNING => error.SQLiteWarning,

        c.SQLITE_ERROR_MISSING_COLLSEQ => error.SQLiteErrorMissingCollSeq,
        c.SQLITE_ERROR_RETRY => error.SQLiteErrorRetry,

        c.SQLITE_IOERR_READ => error.SQLiteIOErrRead,
        c.SQLITE_IOERR_SHORT_READ => error.SQLiteIOErrShortRead,
        c.SQLITE_IOERR_WRITE => error.SQLiteIOErrWrite,
        c.SQLITE_IOERR_FSYNC => error.SQLiteIOErrFsync,
        c.SQLITE_IOERR_DIR_FSYNC => error.SQLiteIOErrDirFsync,
        c.SQLITE_IOERR_TRUNCATE => error.SQLiteIOErrTruncate,
        c.SQLITE_IOERR_FSTAT => error.SQLiteIOErrFstat,
        c.SQLITE_IOERR_UNLOCK => error.SQLiteIOErrUnlock,
        c.SQLITE_IOERR_RDLOCK => error.SQLiteIOErrRDLock,
        c.SQLITE_IOERR_DELETE => error.SQLiteIOErrDelete,
        c.SQLITE_IOERR_BLOCKED => error.SQLiteIOErrBlocked,
        c.SQLITE_IOERR_NOMEM => error.SQLiteIOErrNoMem,
        c.SQLITE_IOERR_ACCESS => error.SQLiteIOErrAccess,
        c.SQLITE_IOERR_CHECKRESERVEDLOCK => error.SQLiteIOErrCheckReservedLock,
        c.SQLITE_IOERR_LOCK => error.SQLiteIOErrLock,
        c.SQLITE_IOERR_CLOSE => error.SQLiteIOErrClose,
        c.SQLITE_IOERR_DIR_CLOSE => error.SQLiteIOErrDirClose,
        c.SQLITE_IOERR_SHMOPEN => error.SQLiteIOErrSHMOpen,
        c.SQLITE_IOERR_SHMSIZE => error.SQLiteIOErrSHMSize,
        c.SQLITE_IOERR_SHMLOCK => error.SQLiteIOErrSHMLock,
        c.SQLITE_IOERR_SHMMAP => error.SQLiteIOErrSHMMap,
        c.SQLITE_IOERR_SEEK => error.SQLiteIOErrSeek,
        c.SQLITE_IOERR_DELETE_NOENT => error.SQLiteIOErrDeleteNoEnt,
        c.SQLITE_IOERR_MMAP => error.SQLiteIOErrMmap,
        c.SQLITE_IOERR_GETTEMPPATH => error.SQLiteIOErrGetTempPath,
        c.SQLITE_IOERR_CONVPATH => error.SQLiteIOErrConvPath,
        c.SQLITE_IOERR_VNODE => error.SQLiteIOErrVnode,
        c.SQLITE_IOERR_AUTH => error.SQLiteIOErrAuth,
        c.SQLITE_IOERR_BEGIN_ATOMIC => error.SQLiteIOErrBeginAtomic,
        c.SQLITE_IOERR_COMMIT_ATOMIC => error.SQLiteIOErrCommitAtomic,
        c.SQLITE_IOERR_ROLLBACK_ATOMIC => error.SQLiteIOErrRollbackAtomic,

        c.SQLITE_LOCKED_SHAREDCACHE => error.SQLiteLockedSharedCache,

        c.SQLITE_BUSY_RECOVERY => error.SQLiteBusyRecovery,
        c.SQLITE_BUSY_SNAPSHOT => error.SQLiteBusySnapshot,

        c.SQLITE_CANTOPEN_NOTEMPDIR => error.SQLiteCantOpenNoTempDir,
        c.SQLITE_CANTOPEN_ISDIR => error.SQLiteCantOpenIsDir,
        c.SQLITE_CANTOPEN_FULLPATH => error.SQLiteCantOpenFullPath,
        c.SQLITE_CANTOPEN_CONVPATH => error.SQLiteCantOpenConvPath,

        c.SQLITE_CORRUPT_VTAB => error.SQLiteCorruptVTab,

        c.SQLITE_READONLY_RECOVERY => error.SQLiteReadOnlyRecovery,
        c.SQLITE_READONLY_CANTLOCK => error.SQLiteReadOnlyCantLock,
        c.SQLITE_READONLY_ROLLBACK => error.SQLiteReadOnlyRollback,
        c.SQLITE_READONLY_DBMOVED => error.SQLiteReadOnlyDBMoved,
        c.SQLITE_READONLY_CANTINIT => error.SQLiteReadOnlyCantInit,
        c.SQLITE_READONLY_DIRECTORY => error.SQLiteReadOnlyDirectory,

        c.SQLITE_ABORT_ROLLBACK => error.SQLiteAbortRollback,

        c.SQLITE_CONSTRAINT_CHECK => error.SQLiteConstraintCheck,
        c.SQLITE_CONSTRAINT_COMMITHOOK => error.SQLiteConstraintCommitHook,
        c.SQLITE_CONSTRAINT_FOREIGNKEY => error.SQLiteConstraintForeignKey,
        c.SQLITE_CONSTRAINT_FUNCTION => error.SQLiteConstraintFunction,
        c.SQLITE_CONSTRAINT_NOTNULL => error.SQLiteConstraintNotNull,
        c.SQLITE_CONSTRAINT_PRIMARYKEY => error.SQLiteConstraintPrimaryKey,
        c.SQLITE_CONSTRAINT_TRIGGER => error.SQLiteConstraintTrigger,
        c.SQLITE_CONSTRAINT_UNIQUE => error.SQLiteConstraintUnique,
        c.SQLITE_CONSTRAINT_VTAB => error.SQLiteConstraintVTab,
        c.SQLITE_CONSTRAINT_ROWID => error.SQLiteConstraintRowID,

        else => std.debug.panic("invalid result code {}", .{code}),
    };
}

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mntent.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <unistd.h>

static bool is_mount_table(const char *path)
{
	return path && (!strcmp(path, "/proc/mounts") || !strcmp(path, "/etc/mtab"));
}

static bool is_blocked(const char *path)
{
	const char *prefix = getenv("NEUTRINO_TEST_BLOCK_PREFIX");
	const char *armed = getenv("NEUTRINO_TEST_BLOCK_ARMED");
	struct stat st;
	size_t length;

	if (!path || !prefix || !*prefix || !armed || !*armed
		|| syscall(SYS_newfstatat, AT_FDCWD, armed, &st, 0))
		return false;
	length = strlen(prefix);
	return !strncmp(path, prefix, length)
		&& (path[length] == '\0' || path[length] == '/');
}

static bool is_blocked_at(int dirfd, const char *path)
{
	char base[PATH_MAX + 1];
	char combined[PATH_MAX * 2 + 2];
	ssize_t length;

	if (!path || path[0] == '/')
		return is_blocked(path);
	if (dirfd == AT_FDCWD)
	{
		if (!getcwd(base, sizeof(base)))
			return false;
	}
	else
	{
		char descriptor[64];

		snprintf(descriptor, sizeof(descriptor), "/proc/self/fd/%d", dirfd);
		length = syscall(SYS_readlinkat, AT_FDCWD, descriptor, base, PATH_MAX);
		if (length < 0)
			return false;
		base[length] = '\0';
	}
	if (snprintf(combined, sizeof(combined), "%s/%s", base, path) >= (int) sizeof(combined))
		return false;
	return is_blocked(combined);
}

static void mark(const char *variable)
{
	const char *path = getenv(variable);
	int fd;

	if (!path || !*path)
		return;
	fd = syscall(SYS_openat, AT_FDCWD, path, O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (fd >= 0)
	{
		(void) syscall(SYS_write, fd, "1\n", 2);
		(void) syscall(SYS_close, fd);
	}
}

static const char *redirect_mount_table(const char *path)
{
	const char *replacement;

	if (!is_mount_table(path))
		return path;
	replacement = getenv("NEUTRINO_TEST_MOUNTS");
	if (!replacement || !*replacement)
		return path;
	mark("NEUTRINO_TEST_MOUNTS_USED");
	return replacement;
}

static void block(void)
{
	mark("NEUTRINO_TEST_BLOCKED");
	sleep(30);
	errno = EIO;
}

FILE *setmntent(const char *filename, const char *type)
{
	static FILE *(*real_setmntent)(const char *, const char *);

	if (!real_setmntent)
		real_setmntent = dlsym(RTLD_NEXT, "setmntent");
	return real_setmntent(redirect_mount_table(filename), type);
}

FILE *fopen(const char *path, const char *mode)
{
	static FILE *(*real_fopen)(const char *, const char *);

	if (!real_fopen)
		real_fopen = dlsym(RTLD_NEXT, "fopen");
	if (is_blocked(path))
	{
		block();
		return NULL;
	}
	return real_fopen(redirect_mount_table(path), mode);
}

FILE *fopen64(const char *path, const char *mode)
{
	static FILE *(*real_fopen64)(const char *, const char *);

	if (!real_fopen64)
		real_fopen64 = dlsym(RTLD_NEXT, "fopen64");
	if (is_blocked(path))
	{
		block();
		return NULL;
	}
	return real_fopen64(redirect_mount_table(path), mode);
}

static mode_t open_mode(int flags, va_list args)
{
	return (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE)
		? va_arg(args, mode_t) : 0;
}

int open(const char *path, int flags, ...)
{
	static int (*real_open)(const char *, int, ...);
	va_list args;
	mode_t mode;

	if (!real_open)
		real_open = dlsym(RTLD_NEXT, "open");
	va_start(args, flags);
	mode = open_mode(flags, args);
	va_end(args);
	if (is_blocked(path))
	{
		block();
		return -1;
	}
	path = redirect_mount_table(path);
	return (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE)
		? real_open(path, flags, mode) : real_open(path, flags);
}

int open64(const char *path, int flags, ...)
{
	static int (*real_open64)(const char *, int, ...);
	va_list args;
	mode_t mode;

	if (!real_open64)
		real_open64 = dlsym(RTLD_NEXT, "open64");
	va_start(args, flags);
	mode = open_mode(flags, args);
	va_end(args);
	if (is_blocked(path))
	{
		block();
		return -1;
	}
	path = redirect_mount_table(path);
	return (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE)
		? real_open64(path, flags, mode) : real_open64(path, flags);
}

int openat(int dirfd, const char *path, int flags, ...)
{
	static int (*real_openat)(int, const char *, int, ...);
	va_list args;
	mode_t mode;

	if (!real_openat)
		real_openat = dlsym(RTLD_NEXT, "openat");
	va_start(args, flags);
	mode = open_mode(flags, args);
	va_end(args);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	path = redirect_mount_table(path);
	return (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE)
		? real_openat(dirfd, path, flags, mode) : real_openat(dirfd, path, flags);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
	static int (*real_openat64)(int, const char *, int, ...);
	va_list args;
	mode_t mode;

	if (!real_openat64)
		real_openat64 = dlsym(RTLD_NEXT, "openat64");
	va_start(args, flags);
	mode = open_mode(flags, args);
	va_end(args);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	path = redirect_mount_table(path);
	return (flags & O_CREAT) || ((flags & O_TMPFILE) == O_TMPFILE)
		? real_openat64(dirfd, path, flags, mode) : real_openat64(dirfd, path, flags);
}

int __open_2(const char *path, int flags)
{
	return open(path, flags);
}

int __open64_2(const char *path, int flags)
{
	return open64(path, flags);
}

int __openat_2(int dirfd, const char *path, int flags)
{
	return openat(dirfd, path, flags);
}

int __openat64_2(int dirfd, const char *path, int flags)
{
	return openat64(dirfd, path, flags);
}

#define BLOCKING_WRAPPER(name, type) \
	int name(const char *path, type *buffer) \
	{ \
		static int (*real_function)(const char *, type *); \
		if (is_blocked(path)) { block(); return -1; } \
		if (!real_function) real_function = dlsym(RTLD_NEXT, #name); \
		return real_function(path, buffer); \
	}

BLOCKING_WRAPPER(stat, struct stat)
BLOCKING_WRAPPER(stat64, struct stat64)
BLOCKING_WRAPPER(lstat, struct stat)
BLOCKING_WRAPPER(lstat64, struct stat64)
BLOCKING_WRAPPER(statfs, struct statfs)
BLOCKING_WRAPPER(statfs64, struct statfs64)
BLOCKING_WRAPPER(statvfs, struct statvfs)
BLOCKING_WRAPPER(statvfs64, struct statvfs64)

int fstatat(int dirfd, const char *path, struct stat *buffer, int flags)
{
	static int (*real_fstatat)(int, const char *, struct stat *, int);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	if (!real_fstatat)
		real_fstatat = dlsym(RTLD_NEXT, "fstatat");
	return real_fstatat(dirfd, path, buffer, flags);
}

int fstatat64(int dirfd, const char *path, struct stat64 *buffer, int flags)
{
	static int (*real_fstatat64)(int, const char *, struct stat64 *, int);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	if (!real_fstatat64)
		real_fstatat64 = dlsym(RTLD_NEXT, "fstatat64");
	return real_fstatat64(dirfd, path, buffer, flags);
}

int newfstatat(int dirfd, const char *path, struct stat *buffer, int flags)
{
	return fstatat(dirfd, path, buffer, flags);
}

int statx(int dirfd, const char *path, int flags, unsigned int mask, struct statx *buffer)
{
	static int (*real_statx)(int, const char *, int, unsigned int, struct statx *);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	if (!real_statx)
		real_statx = dlsym(RTLD_NEXT, "statx");
	return real_statx(dirfd, path, flags, mask, buffer);
}

int access(const char *path, int mode)
{
	static int (*real_access)(const char *, int);
	if (is_blocked(path))
	{
		block();
		return -1;
	}
	if (!real_access)
		real_access = dlsym(RTLD_NEXT, "access");
	return real_access(path, mode);
}

int faccessat(int dirfd, const char *path, int mode, int flags)
{
	static int (*real_faccessat)(int, const char *, int, int);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	if (!real_faccessat)
		real_faccessat = dlsym(RTLD_NEXT, "faccessat");
	return real_faccessat(dirfd, path, mode, flags);
}

ssize_t readlink(const char *path, char *buffer, size_t size)
{
	static ssize_t (*real_readlink)(const char *, char *, size_t);
	if (is_blocked(path))
	{
		block();
		return -1;
	}
	if (!real_readlink)
		real_readlink = dlsym(RTLD_NEXT, "readlink");
	return real_readlink(path, buffer, size);
}

ssize_t readlinkat(int dirfd, const char *path, char *buffer, size_t size)
{
	static ssize_t (*real_readlinkat)(int, const char *, char *, size_t);
	if (is_blocked_at(dirfd, path))
	{
		block();
		return -1;
	}
	if (!real_readlinkat)
		real_readlinkat = dlsym(RTLD_NEXT, "readlinkat");
	return real_readlinkat(dirfd, path, buffer, size);
}

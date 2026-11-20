#pragma once
// macOS ships libarchive and its SDK link stub. Some SDKs omit the C headers.
// Declare the small part of the public read API used for JAR metadata on those SDKs.
#if __has_include(<archive.h>) && __has_include(<archive_entry.h>)
#include <archive.h>
#include <archive_entry.h>
#else
#include <sys/types.h>
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip_seekable(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
const char *archive_entry_pathname(struct archive_entry *);
int archive_read_free(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#endif

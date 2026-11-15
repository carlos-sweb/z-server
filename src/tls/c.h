#ifndef Z_SERVER_TLS_C_H
#define Z_SERVER_TLS_C_H

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include "bearssl.h"

static inline int z_stat_file(const char *path, unsigned int *mode, unsigned long *size) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    if (mode) *mode = (unsigned int)st.st_mode;
    if (size) *size = (unsigned long)st.st_size;
    return 0;
}

static inline int z_fstat_file(int fd, unsigned int *mode, unsigned long *size) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    if (mode) *mode = (unsigned int)st.st_mode;
    if (size) *size = (unsigned long)st.st_size;
    return 0;
}

#endif

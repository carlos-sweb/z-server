#include "bindings.h"

int z_stat_file(const char *path, unsigned int *mode, unsigned long *size) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    if (mode) *mode = (unsigned int)st.st_mode;
    if (size) *size = (unsigned long)st.st_size;
    return 0;
}

int z_fstat_file(int fd, unsigned int *mode, unsigned long *size) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    if (mode) *mode = (unsigned int)st.st_mode;
    if (size) *size = (unsigned long)st.st_size;
    return 0;
}

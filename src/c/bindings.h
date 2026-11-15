#ifndef Z_SERVER_BINDINGS_H
#define Z_SERVER_BINDINGS_H
#include <stdlib.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include "pogocache.h"
#include "bearssl.h"

int z_stat_file(const char *path, unsigned int *mode, unsigned long *size);
int z_fstat_file(int fd, unsigned int *mode, unsigned long *size);

#endif

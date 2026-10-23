#ifndef PRIVATE_TERM_PTY_SHIM_H
#define PRIVATE_TERM_PTY_SHIM_H

#include <sys/types.h>

// Returns 0 on success or an errno value on failure.
// The caller owns *master_fd and must close it.
int pt_spawn_shell(int *master_fd, pid_t *child_pid, unsigned short columns, unsigned short rows,
                   const char *working_directory);
int pt_resize(int master_fd, unsigned short columns, unsigned short rows);

#endif

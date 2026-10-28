/*
 * shm_create - POSIX 共有メモリを作る（試験用ペイロード）
 *
 * 使い方:
 *   shm_create [名前]
 *       shm_open(名前, O_CREAT | O_RDWR, 0666) で作り、名前を標準出力に
 *       出して、成功したら 0 で終わる。失敗したら perror して 1。
 *       名前を省略すると "/box_stage0_shm"。
 *   shm_create --open-only <名前>
 *       O_CREAT 無しで開く。開けたら 0、開けなければ 3。
 *       「別のスロットから開けない」ことの確認に使う（相手の名前空間に
 *       無い共有メモリは O_CREAT 無しでは開けない）。
 *
 * ビルド: cc -O2 -o shm_create shm_create.c -lrt は不要（FreeBSD では libc）
 */
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	const char *name = "/box_stage0_shm";
	int flags = O_CREAT | O_RDWR;
	int open_only = 0;
	int fd;

	if (argc >= 2 && strcmp(argv[1], "--open-only") == 0) {
		if (argc < 3) {
			fprintf(stderr, "usage: shm_create --open-only <name>\n");
			return 64;
		}
		name = argv[2];
		flags = O_RDWR;
		open_only = 1;
	} else if (argc >= 2) {
		name = argv[1];
	}

	fd = shm_open(name, flags, 0666);
	if (fd < 0) {
		perror("shm_open");
		return open_only ? 3 : 1;
	}
	if (!open_only && ftruncate(fd, 4096) != 0) {
		perror("ftruncate");
		return 1;
	}
	printf("%s\n", name);
	fflush(stdout);
	close(fd);
	return 0;
}

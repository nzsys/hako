/*
 * sock_inet - INET ソケットが作れるかを試す（試験用ペイロード）
 *
 * socket(AF_INET) と socket(AF_INET6) を試す。どちらか1つでも作れたら
 * 「ネットワークを持っている」ということなので 1 で終わる（= 試験の
 * 失敗扱い）。両方とも失敗したら、その旨を出して 0 で終わる。
 *
 * スロットの子 jail はネットワークスタックを持たない（ip4/ip6 disable）
 * ので、スロットの中では 0 で終わるのが正しい結果。
 *
 * ビルド: cc -O2 -o sock_inet sock_inet.c
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
try_family(int family, const char *label)
{
	int fd = socket(family, SOCK_STREAM, 0);

	if (fd >= 0) {
		printf("%s: socket created (fd=%d)\n", label, fd);
		close(fd);
		return 1;
	}
	printf("%s: %s\n", label, strerror(errno));
	return 0;
}

int
main(void)
{
	int created = 0;

	created += try_family(AF_INET, "AF_INET");
	created += try_family(AF_INET6, "AF_INET6");
	if (created > 0) {
		printf("RESULT: inet socket available\n");
		return 1;
	}
	printf("RESULT: no inet socket\n");
	return 0;
}

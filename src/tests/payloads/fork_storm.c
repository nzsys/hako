/*
 * fork_storm - 二重 fork + setsid で孫プロセスを残す（試験用）
 *
 * 親は子を fork し、子は setsid してから孫を fork してすぐ終わる。
 * 孫は自セッションのリーダーとして sleep し続ける。親は孫の pid を
 * 標準出力に出して 0 で終わる。
 *
 * 期待される使い方: スロットの中で実行し、振り分けに片付けを
 * させた後、孫 pid のプロセスが残っていないことを確かめる
 *
 * ビルド: cc -O2 -o fork_storm fork_storm.c
 */
#include <sys/types.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int
main(void)
{
	pid_t child, grand;

	child = fork();
	if (child < 0) {
		perror("fork");
		return 1;
	}
	if (child == 0) {
		/* 子: セッションを切り離してから孫を作り、すぐ終わる */
		if (setsid() < 0) {
			perror("setsid");
			_exit(1);
		}
		grand = fork();
		if (grand < 0)
			_exit(1);
		if (grand == 0) {
			/* 孫: 残り続けるのが仕事 */
			for (;;)
				sleep(60);
		}
		printf("grandchild=%ld\n", (long)grand);
		fflush(stdout);
		_exit(0);
	}
	/* 親: 子の終了を待って 0 で終わる（孫は残る） */
	{
		int status;
		if (waitpid(child, &status, 0) < 0) {
			perror("waitpid");
			return 1;
		}
	}
	return 0;
}

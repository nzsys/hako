/*
 * boxfd: スロットの PHP が継承した「受け取り口」を扱う最小の C 拡張。
 *   boxfd_recv_socket(): 受け取り口（既定は fd 3）を stream にし、
 *     socket_import_stream で sockets 拡張の Socket に包む（本命の経路）。
 *   boxfd_relay_fd(): 保険。受け取り口へ SCM_RIGHTS で届いた最初の fd を
 *     生の番号で返し、余分な fd は全部閉じる。
 *   boxfd_send_op(): 保険。中継へ MSG_EOR 付きで1レコード送り、応答の
 *     1レコード（MSG_EOR まで）を文字列で返す。すべて C で完結する。
 * 受け取り口の番号は環境変数 BOX_RECV_FD で上書きできる。
 */
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include "php.h"
#include "ext/standard/info.h"
#include "main/php_streams.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>

#define BOXFD_MAX_MSG (64 * 1024) /* 1メッセージの上限 */
#define BOXFD_MAX_FDS 4           /* 1レコードで受け取る fd の上限 */

/* 受け取り口の fd 番号。環境変数が読めない・不正なら既定の 3。 */
static int recv_fd_number(void)
{
    const char *env = getenv("BOX_RECV_FD");
    if (env != NULL && env[0] != '\0') {
        char *end = NULL;
        long n = strtol(env, &end, 10);
        if (end != env && *end == '\0' && n >= 0 && n < 65536) {
            return (int)n;
        }
    }
    return 3;
}

/* fd が開いているかだけを確かめる（中身は見ない）。 */
static int fd_alive(int fd)
{
    return fd >= 0 && fcntl(fd, F_GETFD) >= 0;
}

/* hdr に届いた fd を処理する。keep_first なら最初の1つを残して返し、
 * それ以外（余分な分、または全部）を即座に閉じる。fd が無ければ -1。 */
static int take_fds(struct msghdr *hdr, int keep_first)
{
    int first = -1;
    struct cmsghdr *c;
    for (c = CMSG_FIRSTHDR(hdr); c != NULL; c = CMSG_NXTHDR(hdr, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            int count = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
            int *fds = (int *)CMSG_DATA(c);
            int i;
            for (i = 0; i < count; i++) {
                if (keep_first && first < 0) {
                    first = fds[i];
                } else {
                    close(fds[i]);
                }
            }
        }
    }
    return first;
}

PHP_FUNCTION(boxfd_recv_socket)
{
    int fd, dupfd;
    php_stream *stream;
    zval params[1], fn, retval;
    zend_string *fname;
    int ok = 0;

    ZEND_PARSE_PARAMETERS_NONE();

    fd = recv_fd_number();
    if (!fd_alive(fd)) { RETURN_FALSE; }
    /* stream の後始末で fd 3 本体まで閉じないよう、複製してから包む。 */
    dupfd = dup(fd);
    if (dupfd < 0) { RETURN_FALSE; }
    stream = php_stream_fopen_from_fd(dupfd, "r+b", NULL);
    if (stream == NULL) {
        close(dupfd);
        RETURN_FALSE;
    }
    php_stream_to_zval(stream, &params[0]);

    /* sockets 拡張が無い環境では Socket 化できない。保険の経路を使う。 */
    fname = zend_string_init("socket_import_stream", sizeof("socket_import_stream") - 1, 0);
    if (zend_hash_find(EG(function_table), fname) == NULL) {
        zend_string_release(fname);
        zval_ptr_dtor(&params[0]);
        RETURN_FALSE;
    }
    ZVAL_UNDEF(&retval);
    ZVAL_STR(&fn, fname);
    if (call_user_function(EG(function_table), NULL, &fn, &retval, 1, params) == SUCCESS
        && Z_TYPE(retval) == IS_OBJECT) {
        ZVAL_COPY_VALUE(return_value, &retval);
        ok = 1;
    } else if (Z_TYPE(retval) != IS_UNDEF) {
        zval_ptr_dtor(&retval);
    }
    zval_ptr_dtor(&fn);
    zval_ptr_dtor(&params[0]);
    if (!ok) { RETURN_FALSE; }
}

PHP_FUNCTION(boxfd_relay_fd)
{
    int fd, first;
    char data[256]; /* fd と一緒に届く小さな JSON は読み捨てる */
    char control[CMSG_SPACE(sizeof(int) * BOXFD_MAX_FDS)];
    struct iovec iov;
    struct msghdr hdr;
    ssize_t n;

    ZEND_PARSE_PARAMETERS_NONE();

    fd = recv_fd_number();
    if (!fd_alive(fd)) { RETURN_FALSE; }
    memset(&hdr, 0, sizeof(hdr));
    memset(control, 0, sizeof(control));
    iov.iov_base = data;
    iov.iov_len = sizeof(data);
    hdr.msg_iov = &iov;
    hdr.msg_iovlen = 1;
    hdr.msg_control = control;
    hdr.msg_controllen = sizeof(control);
    do {
        n = recvmsg(fd, &hdr, 0);
    } while (n < 0 && errno == EINTR);
    first = (n > 0) ? take_fds(&hdr, 1) : -1;
    if (first < 0) { RETURN_FALSE; }
    RETURN_LONG(first);
}

PHP_FUNCTION(boxfd_send_op)
{
    zend_long fd;
    char *json;
    size_t json_len, used = 0;
    char *buf;
    struct iovec iov;
    struct msghdr hdr;
    ssize_t n;

    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_LONG(fd)
        Z_PARAM_STRING(json, json_len)
    ZEND_PARSE_PARAMETERS_END();

    if (fd < 0 || fd >= 65536 || json_len == 0 || json_len > BOXFD_MAX_MSG) {
        RETURN_FALSE;
    }
    /* 送る: fd は付けず、MSG_EOR でレコードの境界を作る。 */
    memset(&hdr, 0, sizeof(hdr));
    iov.iov_base = json;
    iov.iov_len = json_len;
    hdr.msg_iov = &iov;
    hdr.msg_iovlen = 1;
    do {
        n = sendmsg((int)fd, &hdr, MSG_EOR);
    } while (n < 0 && errno == EINTR);
    if (n < 0 || (size_t)n != json_len) {
        RETURN_FALSE;
    }
    /* 受ける: 上限+1 のバッファで読み、MSG_EOR の立つレコードまで本文を
     * 組み立てる。応答に fd が付いていたら契約外なので即座に閉じる。 */
    buf = emalloc(BOXFD_MAX_MSG + 1);
    for (;;) {
        char control[CMSG_SPACE(sizeof(int) * BOXFD_MAX_FDS)];
        memset(&hdr, 0, sizeof(hdr));
        memset(control, 0, sizeof(control));
        iov.iov_base = buf + used;
        iov.iov_len = (BOXFD_MAX_MSG + 1) - used;
        hdr.msg_iov = &iov;
        hdr.msg_iovlen = 1;
        hdr.msg_control = control;
        hdr.msg_controllen = sizeof(control);
        do {
            n = recvmsg((int)fd, &hdr, 0);
        } while (n < 0 && errno == EINTR);
        if (n <= 0) {
            efree(buf);
            RETURN_FALSE;
        }
        (void)take_fds(&hdr, 0);
        used += (size_t)n;
        if (used > BOXFD_MAX_MSG) {
            efree(buf);
            RETURN_FALSE;
        }
        if (hdr.msg_flags & MSG_EOR) {
            break;
        }
    }
    {
        zend_string *zs = zend_string_init(buf, used, 0);
        efree(buf);
        RETURN_NEW_STR(zs);
    }
}

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_MASK_EX(arginfo_boxfd_recv_socket, 0, 0, MAY_BE_OBJECT | MAY_BE_FALSE)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_MASK_EX(arginfo_boxfd_relay_fd, 0, 0, MAY_BE_LONG | MAY_BE_FALSE)
ZEND_END_ARG_INFO()

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_MASK_EX(arginfo_boxfd_send_op, 0, 2, MAY_BE_STRING | MAY_BE_FALSE)
    ZEND_ARG_TYPE_INFO(0, fd, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, json, IS_STRING, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry boxfd_functions[] = {
    PHP_FE(boxfd_recv_socket, arginfo_boxfd_recv_socket)
    PHP_FE(boxfd_relay_fd, arginfo_boxfd_relay_fd)
    PHP_FE(boxfd_send_op, arginfo_boxfd_send_op)
    PHP_FE_END
};

PHP_MINFO_FUNCTION(boxfd)
{
    php_info_print_table_start();
    php_info_print_table_row(2, "boxfd support", "enabled");
    php_info_print_table_end();
}

zend_module_entry boxfd_module_entry = {
    STANDARD_MODULE_HEADER,
    "boxfd",
    boxfd_functions,
    NULL, NULL, NULL, NULL,
    PHP_MINFO(boxfd),
    "0.1.0",
    STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_BOXFD
ZEND_GET_MODULE(boxfd)
#endif

dnl boxfd: スロットの PHP が継承した「受け取り口」を扱う最小の拡張。
dnl ビルドは phpize からの通常の手順でよい。
PHP_ARG_ENABLE([boxfd],
  [whether to enable boxfd support],
  [AS_HELP_STRING([--enable-boxfd], [Enable boxfd support])], [no])

if test "$PHP_BOXFD" != "no"; then
  AC_DEFINE([HAVE_BOXFD], [1], [Whether boxfd is enabled])
  PHP_NEW_EXTENSION([boxfd], [boxfd.c], [$ext_shared],, [-DZEND_ENABLE_STATIC_TSRMLS_CACHE=1])
fi

#!/bin/sh
# FreeBSD の機構スモークテストの起動用（tests/fbsd_smoke.py を参照）。
# 実機・仮想マシン・CI のどこでも同じ: python3 tests/fbsd-smoke.sh
set -eu
cd "$(dirname "$0")"
exec python3 fbsd_smoke.py

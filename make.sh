#!/bin/bash

# 1. 기존 빌드 정리 (옵션 변경 시 필수)
make clean

# 2. 디버그 심볼 포함 빌드
# make dbg db_bench -j 96
make static_lib db_bench -j 96
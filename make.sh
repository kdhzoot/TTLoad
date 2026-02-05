#!/bin/bash

make clean

make static_lib db_bench -j 96

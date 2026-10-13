#!/bin/bash

is_core_dir=$1
is_log_dir=$2
. "$(dirname "$0")/log.sh"

while :; do
    log_limit_check
    sleep 10
done

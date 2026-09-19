#!/bin/bash
# usage: run.sh <label> <script> <args...>
label=$1; script=$2; shift 2
export FM_SPAWN_NO_GUARD=1 FM_HOME=/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm4574-live/firstmate
{ echo "$ $script $*"; "/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm4574-live/firstmate/bin/$script" "$@"; } > "/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm4574-live/out/$label.log" 2>&1
echo $? > "/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm4574-live/out/$label.rc"

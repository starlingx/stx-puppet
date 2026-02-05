#!/bin/bash

function LOG {
    logger -p "daemon.info" "[$$]: $*"
    }

if [ -f /var/run/kubelet-cleanup-orphaned-volumes-executed.flag ]; then
    exit 0
fi

touch /var/run/kubelet-cleanup-orphaned-volumes-executed.flag
LOG "$(find /var/lib/kubelet/pods -type d -name 'volume*' -prune -exec rm -rf {} \; 2>&1)"

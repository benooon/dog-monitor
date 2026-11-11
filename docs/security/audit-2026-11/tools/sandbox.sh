#!/bin/bash
# OS-enforced sandbox for bounded local checks (security-audit skill).
# Usage (as root): sandbox.sh <scratch-dir> <timeout-seconds> <command...>
# Controls: new net/mount/pid/ipc/uts namespaces (no external network; loopback only),
# whole filesystem remounted read-only except <scratch-dir> and a private /tmp tmpfs,
# empty environment with an explicit allowlist, runs as uid/gid of user "postgres" (unprivileged),
# rlimits: CPU, data segment (memory), processes, file size, open files; wall clock via timeout.
set -euo pipefail
SCRATCH=$(realpath "$1"); TIMEOUT=$2; shift 2
chown -R postgres:postgres "$SCRATCH"
exec timeout -k 5 "$TIMEOUT" unshare --net --mount --pid --ipc --uts --fork --mount-proc env -i \
  SCRATCH="$SCRATCH" PATH=/usr/local/bin:/usr/bin:/bin:/usr/lib/postgresql/16/bin \
  bash -c '
set -e
python3 -I -c "
import socket,fcntl,struct
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
ifr=struct.pack(\"16sH\",b\"lo\",0); f=struct.unpack(\"16sH\",fcntl.ioctl(s,0x8913,ifr))[1]
fcntl.ioctl(s,0x8914,struct.pack(\"16sH\",b\"lo\",f|1))"
mount --make-rprivate /
mount -t tmpfs -o size=256m,mode=1777 tmpfs /tmp
mount --bind "$SCRATCH" "$SCRATCH"
# read-only everything else
for m in $(findmnt -rn -o TARGET | sort -r); do
  case "$m" in "$SCRATCH"|/tmp|/proc|/proc/*|/sys/*|/dev|/dev/*) continue;; esac
  mount -o remount,bind,ro "$m" 2>/dev/null || true
done
mount -o remount,bind,ro / 
cd "$SCRATCH"
exec setpriv --reuid=postgres --regid=postgres --init-groups --no-new-privs \
  prlimit --cpu=300 --data=4294967296 --nproc=256 --fsize=268435456 --nofile=1024 -- \
  env -i HOME="$SCRATCH/home" SCRATCH="$SCRATCH" TMPDIR=/tmp PATH=/usr/local/bin:/usr/bin:/bin:/usr/lib/postgresql/16/bin LANG=C.UTF-8 NODE_ENV=test "$@"
' sandbox "$@"

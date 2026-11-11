#!/usr/bin/env python3
"""Trusted parent-side artifact promotion (security-audit SKILL.md "Write isolation").

Usage: promote.py <agent-dir> <scratch-relative-path> [<max-bytes>]
Copies <agent-dir>/scratch/<path> to <agent-dir>/artifacts/<path> using descriptor-relative,
no-follow traversal; only regular files with link count 1 within the byte limit are promoted.
"""
import os
import stat
import sys

PER_FILE_LIMIT = 1024 * 1024


def walk_dirs(root_fd, parts, create=False):
    fd = os.dup(root_fd)
    for part in parts:
        try:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        except FileNotFoundError:
            if not create:
                os.close(fd)
                raise
            os.mkdir(part, 0o755, dir_fd=fd)
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        os.close(fd)
        if not stat.S_ISDIR(os.fstat(nfd).st_mode):
            os.close(nfd)
            raise ValueError(f"not a directory: {part}")
        fd = nfd
    return fd


def main():
    agent_dir, rel = sys.argv[1], sys.argv[2]
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else PER_FILE_LIMIT
    parts = rel.split("/")
    if rel.startswith("/") or not rel or any(p in ("", ".", "..") for p in parts):
        sys.exit(f"rejected path: {rel!r}")
    scratch_root = os.open(os.path.join(agent_dir, "scratch"), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    art_root = os.open(os.path.join(agent_dir, "artifacts"), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    src_dir = walk_dirs(scratch_root, parts[:-1])
    src = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=src_dir)
    st = os.fstat(src)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size > limit:
        sys.exit("rejected: not a single-link regular file within the limit")
    data = b""
    while len(data) <= st.st_size:
        chunk = os.read(src, 65536)
        if not chunk:
            break
        data += chunk
        if len(data) > limit:
            sys.exit("rejected: grew past the limit")
    st2 = os.fstat(src)
    if (st2.st_ino, st2.st_dev, st2.st_nlink, st2.st_size) != (st.st_ino, st.st_dev, st.st_nlink, st.st_size) or len(data) != st.st_size:
        sys.exit("rejected: file changed during copy")
    dst_dir = walk_dirs(art_root, parts[:-1], create=True)
    dst = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dst_dir)
    dst_st = os.fstat(dst)
    if not stat.S_ISREG(dst_st.st_mode) or dst_st.st_nlink != 1:
        sys.exit("rejected: bad destination")
    os.write(dst, data)
    os.close(dst)
    print(f"promoted agents/{os.path.basename(os.path.normpath(agent_dir))}/artifacts/{rel} ({len(data)} bytes)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Minimal newc cpio reader/writer, so the payload check needs no cpio binary.

    cpio-tool.py list     <archive[.gz]>
    cpio-tool.py extract  <archive[.gz]> <destdir>
    cpio-tool.py create   <sourcedir> <archive[.gz]>
"""

import gzip
import io
import os
import stat
import sys

MAGIC = (b"070701", b"070702")


def _open(path, mode):
    # Decide by content, not by name: initramfs files come out of a FAT image
    # with no extension even though they are gzip-compressed.
    if "r" in mode:
        with open(path, "rb") as probe:
            gz = probe.read(2) == b"\x1f\x8b"
        return gzip.open(path, "rb") if gz else open(path, mode)
    if path.endswith(".gz") or mode.endswith("b"):
        return gzip.open(path, "wb") if path.endswith(".gz") else open(path, mode)
    return open(path, mode)


def read_entries(fh):
    entries = []
    while True:
        hdr = fh.read(110)
        if len(hdr) < 110 or hdr[:6] not in MAGIC:
            break
        fields = [int(hdr[6 + i * 8: 14 + i * 8], 16) for i in range(13)]
        mode, filesize, namesize = fields[1], fields[6], fields[11]
        name = fh.read(namesize - 1).decode("utf-8", "replace")
        fh.read(1)  # NUL
        fh.read((4 - ((110 + namesize) % 4)) % 4)
        data = fh.read(filesize)
        fh.read((4 - (filesize % 4)) % 4)
        if name == "TRAILER!!!":
            break
        entries.append((name, mode, data))
    return entries


def safe(name):
    parts = [p for p in name.split("/") if p not in ("", ".", "..")]
    return os.path.join(*parts) if parts else ""


def cmd_list(path):
    with _open(path, "rb") as fh:
        for name, mode, data in read_entries(fh):
            print(f"{stat.filemode(mode):10s} {len(data):>9d} {name}")


def cmd_extract(path, dest):
    with _open(path, "rb") as fh:
        for name, mode, data in read_entries(fh):
            rel = safe(name)
            if not rel:
                continue
            target = os.path.join(dest, rel)
            if stat.S_ISDIR(mode):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target) or dest, exist_ok=True)
            with open(target, "wb") as out:
                out.write(data)
            os.chmod(target, mode & 0o7777 or 0o644)
    print(f"extracted to {dest}", file=sys.stderr)


def cmd_create(src, out_path):
    buf = io.BytesIO()
    ino = 1

    def emit(name, mode, data):
        nonlocal ino
        raw = name.encode() + b"\0"
        buf.write(b"070701")
        buf.write(b"%08X" % ino)
        buf.write(b"%08X" % mode)
        buf.write(b"%08X%08X%08X%08X" % (0, 0, 1, 0))
        buf.write(b"%08X" % len(data))
        buf.write(b"%08X%08X%08X%08X" % (0, 0, 0, 0))
        buf.write(b"%08X" % len(raw))
        buf.write(b"%08X" % 0)
        buf.write(raw)
        buf.write(b"\0" * ((4 - ((110 + len(raw)) % 4)) % 4))
        buf.write(data)
        buf.write(b"\0" * ((4 - (len(data) % 4)) % 4))
        ino += 1

    for root, dirs, files in os.walk(src):
        dirs.sort()
        rel_root = os.path.relpath(root, src)
        if rel_root != ".":
            emit(rel_root + "/", stat.S_IFDIR | 0o755, b"")
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            with open(full, "rb") as fh:
                emit(rel, stat.S_IFREG | (os.stat(full).st_mode & 0o777), fh.read())
    emit("TRAILER!!!", 0, b"")

    with _open(out_path, "wb" if out_path.endswith(".gz") else "wb") as fh:
        fh.write(buf.getvalue())
    print(f"wrote {out_path} ({len(buf.getvalue())} bytes)", file=sys.stderr)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "list":
        cmd_list(sys.argv[2])
    elif cmd == "extract":
        cmd_extract(sys.argv[2], sys.argv[3])
    elif cmd == "create":
        cmd_create(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

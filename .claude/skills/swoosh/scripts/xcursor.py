"""Read and write Xcursor files (the format of /usr/share/icons/*/cursors/*).

File: "Xcur", header size 16, version, ntoc; then ntoc TOC entries (type, size, offset);
image chunk: header 36, type, nominal size, version 1, w, h, xhot, yhot, delay, w*h ARGB u32.
"""

import struct
from pathlib import Path

IMAGE = 0xFFFD0002


def read_largest(path):
    """Largest image of a cursor file as (width, height, xhot, yhot, premultiplied BGRA bytes)."""
    data = Path(path).read_bytes()
    magic, _, _, ntoc = struct.unpack("<4sIII", data[:16])
    if magic != b"Xcur":
        raise ValueError(f"{path}: not an Xcursor file")
    toc = [struct.unpack("<III", data[16 + 12 * i:28 + 12 * i]) for i in range(ntoc)]
    _, _, pos = max((t for t in toc if t[0] == IMAGE), key=lambda t: t[1])
    w, h, xhot, yhot = struct.unpack("<IIII", data[pos + 16:pos + 32])
    pixels = data[pos + 36:pos + 36 + 4 * w * h]
    return w, h, xhot, yhot, pixels


def write_transparent(path, sizes=(24, 32, 48, 64, 96)):
    """A cursor file whose images are all fully transparent."""
    chunks, toc = [], []
    offset = 16 + 12 * len(sizes)
    for size in sizes:
        chunk = struct.pack("<IIIIIIIII", 36, IMAGE, size, 1, size, size, 0, 0, 0)
        chunk += bytes(4 * size * size)
        toc.append(struct.pack("<III", IMAGE, size, offset))
        chunks.append(chunk)
        offset += len(chunk)
    header = struct.pack("<4sIII", b"Xcur", 16, 0x10000, len(sizes))
    Path(path).write_bytes(header + b"".join(toc) + b"".join(chunks))


def make_invisible_theme(root, like="/usr/share/icons/Adwaita/cursors"):
    """Theme 'invisible' under root, with every cursor name the reference theme has."""
    cursors = Path(root) / "invisible" / "cursors"
    cursors.mkdir(parents=True, exist_ok=True)
    (Path(root) / "invisible" / "index.theme").write_text("[Icon Theme]\nName=invisible\n")
    blank = cursors / "default"
    write_transparent(blank)
    for name in Path(like).iterdir():
        target = cursors / name.name
        if not target.exists():
            target.symlink_to("default")
    return Path(root)


if __name__ == "__main__":
    import sys
    make_invisible_theme(sys.argv[1])

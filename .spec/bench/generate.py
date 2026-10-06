# /// script
# requires-python = ">=3.10"
# dependencies = ["pmtiles==3.8.1"]
# ///
"""Generate the shared benchmark input: bench/bench.pmtiles and bench/coords.txt.

Run from the repo root:  uv run bench/generate.py
Deterministic (SHA-256 based, stored-block gzip as in conformance/generate/generate.py),
so re-running gives identical bytes on every platform. Prints the checksum every port's
harness must reproduce: the total byte length of all tiles returned for coords.txt.
"""
import gzip
import hashlib
import io
import struct
import zlib
from pathlib import Path


def gzip_stored(data: bytes, compresslevel: int = 9, *, mtime: float | None = 0) -> bytes:
    out = bytearray(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff")
    chunks = [data[i:i + 65535] for i in range(0, len(data), 65535)] or [b""]
    for n, chunk in enumerate(chunks):
        out += bytes([1 if n == len(chunks) - 1 else 0])
        out += struct.pack("<HH", len(chunk), len(chunk) ^ 0xFFFF) + chunk
    out += struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)
    return bytes(out)


gzip.compress = gzip_stored

import pmtiles.tile as ot  # noqa: E402
from pmtiles.reader import MemorySource, Reader  # noqa: E402
from pmtiles.writer import Writer  # noqa: E402

HERE = Path(__file__).resolve().parent
MAX_ZOOM, POOL, COORDS = 8, 2000, 10_000


def h(s: str) -> int:
    return int.from_bytes(hashlib.sha256(s.encode()).digest()[:8], "big")


def blob(i: int) -> bytes:
    d = hashlib.sha256(f"bench blob {i}".encode()).digest() * 8
    return d[: 16 + d[0] % 200]  # 16-215 bytes, like small vector tiles


buf = io.BytesIO()
w = Writer(buf)
for tid in range(ot.zxy_to_tileid(MAX_ZOOM + 1, 0, 0)):
    w.write_tile(tid, blob(h(f"tile {tid}") % POOL))
w.finalize({"tile_compression": ot.Compression.NONE, "tile_type": ot.TileType.UNKNOWN,
            "min_lon_e7": -742590000, "min_lat_e7": 404770000, "max_lon_e7": -737000000, "max_lat_e7": 409170000},
           {"name": "bench"})
archive = buf.getvalue()
(HERE / "bench.pmtiles").write_bytes(archive)

coords = []
for i in range(COORDS):
    z = h(f"z {i}") % (MAX_ZOOM + 2)  # zooms 0..9; zoom 9 is absent from the archive
    coords.append((z, h(f"x {i}") % (1 << z), h(f"y {i}") % (1 << z)))
(HERE / "coords.txt").write_text("".join(f"{z}/{x}/{y}\n" for z, x, y in coords))

reader = Reader(MemorySource(archive))
found = [reader.get(*c) for c in coords]
total = sum(len(t) for t in found if t is not None)
hdr = ot.deserialize_header(archive)
print(f"bench.pmtiles: {len(archive)} bytes, {hdr['tile_entries_count']} entries, leaves {hdr['leaf_directory_length']} bytes")
print(f"coords.txt: {COORDS} lookups, {sum(t is None for t in found)} absent, checksum (total tile bytes) = {total}")

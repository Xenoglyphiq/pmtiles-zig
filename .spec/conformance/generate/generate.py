# /// script
# requires-python = ">=3.10"
# dependencies = ["pmtiles==3.8.1"]
# ///
"""Generate conformance/manifest.json and conformance/cases/ for the pmtiles spec.

Run from the repo root:  uv run conformance/generate/generate.py

Sources (DECISIONS.md D-004):
  - "oracle": the pinned oracle (pmtiles==3.8.1) builds the archives and computes the
    expected output for valid inputs.
  - "spec":   errors, limits, and archives the oracle's writer can't produce are built here
    and their expected output comes from the spec transcription below (spec/SPEC.md §3).

Every oracle result is cross-checked against the transcription, so a disagreement fails
generation. Output is deterministic: re-running produces identical bytes.
"""
from __future__ import annotations

import base64
import gzip
import hashlib
import io
import json
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path


def gzip_stored(data: bytes, compresslevel: int = 9, *, mtime: float | None = 0) -> bytes:
    """gzip with deflate *stored* blocks: valid gzip that every decoder reads, and
    byte-identical on every platform. zlib and zlib-ng (which Python builds use on
    different platforms) compress the same input to different bytes, which made the
    fixtures irreproducible across machines (DECISIONS.md D-004)."""
    out = bytearray(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff")  # no flags, mtime 0, OS unknown
    chunks = [data[i:i + 65535] for i in range(0, len(data), 65535)] or [b""]
    for n, chunk in enumerate(chunks):
        out += bytes([1 if n == len(chunks) - 1 else 0])  # BFINAL, BTYPE=00 (stored)
        out += struct.pack("<HH", len(chunk), len(chunk) ^ 0xFFFF) + chunk
    out += struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)
    return bytes(out)


# The oracle's writer calls gzip.compress for every directory and the metadata. Route it
# through the platform-independent version before the oracle is imported or used.
gzip.compress = gzip_stored

import pmtiles.tile as ot
from pmtiles.reader import MemorySource, Reader
from pmtiles.writer import Writer

ORACLE = {"language": "python", "package": "pmtiles", "version": "3.8.1", "script": "generate/generate.py"}
SPEC_VERSION = "0.1.0"
GENERATED_AT = "2026-10-06T00:00:00Z"  # bump by hand when cases change
ROOT = Path(__file__).resolve().parents[1]
CASES = ROOT / "cases"

U64_MAX = 2**64 - 1
MAX_TILE_ID = (4**32 - 1) // 3 - 1  # last id at zoom 31
LIMITS = {"max_directory_entries": 1_000_000, "max_directory_bytes": 16_777_216,
          "max_leaf_depth": 4, "max_metadata_bytes": 16_777_216}
COMPRESSION = ["unknown", "none", "gzip", "brotli", "zstd"]
TILE_TYPE = ["unknown", "mvt", "png", "jpeg", "webp", "avif"]

# ---------------------------------------------------------------------------
# Spec transcription (spec/SPEC.md §3). Raises SpecError(code, kind).
# ---------------------------------------------------------------------------

KIND = {
    "pmtiles.truncated": "invalid_input", "pmtiles.bad_magic": "invalid_input",
    "pmtiles.unsupported_version": "unsupported", "pmtiles.varint_overflow": "invalid_input",
    "pmtiles.directory_too_large": "limit_exceeded", "pmtiles.invalid_directory": "invalid_input",
    "pmtiles.invalid_zoom": "invalid_input", "pmtiles.tile_out_of_range": "invalid_input",
    "pmtiles.unsupported_compression": "unsupported", "pmtiles.leaf_depth_exceeded": "limit_exceeded",
    "pmtiles.metadata_too_large": "limit_exceeded",
}


class SpecError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def u64_json(n: int):
    """Canonical JSON: integers beyond ±2^53 are decimal strings."""
    return n if n <= 2**53 else str(n)


def enum_json(names: list[str], raw: int):
    return names[raw] if raw < len(names) else {"unknown": raw}


def spec_decode_header(b: bytes) -> dict:
    if len(b) < 127:
        raise SpecError("pmtiles.truncated")
    if b[0:7] != b"PMTiles":
        raise SpecError("pmtiles.bad_magic")
    if b[7] != 3:
        raise SpecError("pmtiles.unsupported_version")
    u = lambda o: struct.unpack_from("<Q", b, o)[0]
    i = lambda o: struct.unpack_from("<i", b, o)[0]
    deg = lambda o: i(o) / 1e7
    count = lambda o: None if u(o) == 0 else u64_json(u(o))
    return {
        "spec_version": 3,
        "root_directory_offset": u64_json(u(8)), "root_directory_length": u64_json(u(16)),
        "metadata_offset": u64_json(u(24)), "metadata_length": u64_json(u(32)),
        "leaf_directories_offset": u64_json(u(40)), "leaf_directories_length": u64_json(u(48)),
        "tile_data_offset": u64_json(u(56)), "tile_data_length": u64_json(u(64)),
        "addressed_tiles_count": count(72), "tile_entries_count": count(80), "tile_contents_count": count(88),
        "clustered": b[96] == 1,
        "internal_compression": enum_json(COMPRESSION, b[97]),
        "tile_compression": enum_json(COMPRESSION, b[98]),
        "tile_type": enum_json(TILE_TYPE, b[99]),
        "min_zoom": b[100], "max_zoom": b[101],
        "bounds": {"min_lon": deg(102), "min_lat": deg(106), "max_lon": deg(110), "max_lat": deg(114)},
        "center_zoom": b[118],
        "center": {"lon": deg(119), "lat": deg(123)},
    }


class Cursor:
    def __init__(self, b: bytes):
        self.b, self.i = b, 0

    def varint(self) -> int:
        result, shift = 0, 0
        for n in range(10):
            if self.i >= len(self.b):
                raise SpecError("pmtiles.truncated")
            byte = self.b[self.i]
            self.i += 1
            if n == 9 and byte > 1:  # the 10th byte may only carry bit 63
                raise SpecError("pmtiles.varint_overflow")
            result |= (byte & 0x7F) << shift
            if byte < 0x80:
                return result
            shift += 7
        raise SpecError("pmtiles.varint_overflow")


@dataclass
class Entry:
    tile_id: int
    offset: int
    length: int
    run_length: int

    def json(self):
        return {"tile_id": u64_json(self.tile_id), "offset": u64_json(self.offset),
                "length": self.length, "run_length": self.run_length}


def spec_decode_directory(b: bytes, max_entries: int = LIMITS["max_directory_entries"]) -> list[Entry]:
    c = Cursor(b)
    n = c.varint()
    if n > max_entries:
        raise SpecError("pmtiles.directory_too_large")
    entries, last = [], 0
    for k in range(n):
        delta = c.varint()
        if k > 0 and delta == 0:
            raise SpecError("pmtiles.invalid_directory")  # tile ids must strictly increase
        last += delta
        if last > U64_MAX:
            raise SpecError("pmtiles.invalid_directory")
        entries.append(Entry(last, 0, 0, 0))
    for e in entries:
        e.run_length = c.varint()
        if e.run_length > 2**32 - 1:
            raise SpecError("pmtiles.invalid_directory")
    for e in entries:
        e.length = c.varint()
        if e.length > 2**32 - 1:
            raise SpecError("pmtiles.invalid_directory")
    for k, e in enumerate(entries):
        v = c.varint()
        if v == 0:
            if k == 0:
                raise SpecError("pmtiles.invalid_directory")  # nothing to continue from
            e.offset = entries[k - 1].offset + entries[k - 1].length
        else:
            e.offset = v - 1
        if e.offset > U64_MAX:
            raise SpecError("pmtiles.invalid_directory")
    return entries  # trailing bytes are ignored (A2)


def spec_zxy_to_tile_id(z: int, x: int, y: int) -> int:
    if z > 31:
        raise SpecError("pmtiles.invalid_zoom")
    if x >= 1 << z or y >= 1 << z:
        raise SpecError("pmtiles.tile_out_of_range")
    return ot.zxy_to_tileid(z, x, y)  # the Hilbert walk itself is cross-checked below


def spec_tile_id_to_zxy(tile_id: int) -> tuple[int, int, int]:
    if tile_id > MAX_TILE_ID:
        raise SpecError("pmtiles.invalid_zoom")
    return ot.tileid_to_zxy(tile_id)


def spec_find_entry(entries: list[Entry], tile_id: int) -> Entry | None:
    lo, hi = 0, len(entries) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if entries[mid].tile_id < tile_id:
            lo = mid + 1
        elif entries[mid].tile_id > tile_id:
            hi = mid - 1
        else:
            return entries[mid]
    if hi >= 0:  # hi is the last entry with tile_id < tile_id
        e = entries[hi]
        if e.run_length == 0 or tile_id - e.tile_id < e.run_length:
            return e
    return None


def decompress(data: bytes, raw: int) -> bytes:
    if raw == 1:
        return data
    if raw == 2:
        return gzip.decompress(data)
    raise SpecError("pmtiles.unsupported_compression")


def spec_get_tile(archive: bytes, z: int, x: int, y: int) -> bytes | None:
    h = spec_decode_header(archive[:127])
    comp = archive[97]
    tid = spec_zxy_to_tile_id(z, x, y)
    off, length = int(h["root_directory_offset"]), int(h["root_directory_length"])
    for depth in range(LIMITS["max_leaf_depth"] + 1):
        entries = spec_decode_directory(decompress(archive[off:off + length], comp))
        e = spec_find_entry(entries, tid)
        if e is None:
            return None
        if e.run_length > 0:
            start = int(h["tile_data_offset"]) + e.offset
            return archive[start:start + e.length]
        off, length = int(h["leaf_directories_offset"]) + e.offset, e.length
    raise SpecError("pmtiles.leaf_depth_exceeded")


def spec_read_metadata(archive: bytes) -> str:
    h = spec_decode_header(archive[:127])
    if int(h["metadata_length"]) > LIMITS["max_metadata_bytes"]:
        raise SpecError("pmtiles.metadata_too_large")
    off = int(h["metadata_offset"])
    return decompress(archive[off:off + int(h["metadata_length"])], archive[97]).decode("utf-8")


# ---------------------------------------------------------------------------
# Archives
# ---------------------------------------------------------------------------

NYC = {"min_lon_e7": -742590000, "min_lat_e7": 404770000, "max_lon_e7": -737000000,
       "max_lat_e7": 409170000, "center_zoom": 3, "center_lon_e7": -739800000, "center_lat_e7": 407500000}


def tile_bytes(z: int, x: int, y: int) -> bytes:
    """Deterministic tile content with varied lengths (so directories don't compress away)."""
    tid = ot.zxy_to_tileid(z, x, y)
    return (f"{tid:x}." * (1 + (tid * 2654435761) % 3)).encode()


def build_archive(tiles: list[tuple[int, int, int, bytes]], metadata: dict) -> bytes:
    buf = io.BytesIO()
    w = Writer(buf)
    for z, x, y, data in sorted(tiles, key=lambda t: ot.zxy_to_tileid(*t[:3])):
        w.write_tile(ot.zxy_to_tileid(z, x, y), data)
    header = {"tile_compression": ot.Compression.NONE, "tile_type": ot.TileType.UNKNOWN, **NYC}
    w.finalize(header, metadata)
    return buf.getvalue()


def small_archive() -> bytes:
    """z0-z3, with a run of identical "ocean" tiles at z3 so the writer emits run_length > 1."""
    tiles = []
    for z in range(4):
        for x in range(1 << z):
            for y in range(1 << z):
                ocean = z == 3 and ot.zxy_to_tileid(z, x, y) in range(21, 29)
                tiles.append((z, x, y, b"ocean" if ocean else tile_bytes(z, x, y)))
    tiles = [t for t in tiles if (t[0], t[1], t[2]) != (3, 7, 7)]  # one tile absent
    return build_archive(tiles, {"name": "small", "description": "z0-z3 test archive"})


LEAVES_MAX_ZOOM = 7
POOL = 1000


def blob(i: int) -> bytes:
    """Deterministic pseudo-random content, 1-47 bytes (SHA-256, stable across Python versions)."""
    d = hashlib.sha256(f"pmtiles-spec blob {i}".encode()).digest() * 2
    return d[1:1 + 1 + d[0] % 47]


def leaves_archive() -> bytes:
    """Every tile z0-z7, each drawing its content from a pool of POOL blobs. The writer
    de-duplicates, so lengths and offsets are irregular, the directory doesn't compress
    away, and it overflows the 16 KiB root into leaf directories (as real archives do)."""
    tiles = []
    for z in range(LEAVES_MAX_ZOOM + 1):
        for x in range(1 << z):
            for y in range(1 << z):
                pick = int.from_bytes(hashlib.sha256(f"tile {z}/{x}/{y}".encode()).digest()[:4], "big") % POOL
                tiles.append((z, x, y, blob(pick)))
    return build_archive(tiles, {"name": "leaves", "vector_layers": []})


def recompress_internal(archive: bytes, raw: int) -> bytes:
    """Rewrite an oracle archive with a different internal compression (spec-sourced variants)."""
    h = ot.deserialize_header(archive[:127])
    root = gzip.decompress(archive[h["root_offset"]:h["root_offset"] + h["root_length"]])
    meta = gzip.decompress(archive[h["metadata_offset"]:h["metadata_offset"] + h["metadata_length"]])
    assert h["leaf_directory_length"] == 0, "variant archives must have no leaves"
    tiles = archive[h["tile_data_offset"]:h["tile_data_offset"] + h["tile_data_length"]]
    out = bytearray(archive[:127])
    out[97] = raw
    struct.pack_into("<QQQQQQ", out, 8, 127, len(root), 127 + len(root), len(meta),
                     127 + len(root) + len(meta), 0)
    struct.pack_into("<QQ", out, 56, 127 + len(root) + len(meta), len(tiles))
    return bytes(out) + root + meta + tiles


# ---------------------------------------------------------------------------
# Case builders
# ---------------------------------------------------------------------------

cases: list[dict] = []
files: dict[str, bytes] = {}


def add(case: dict) -> None:
    cases.append({k: v for k, v in case.items() if v is not None})


def put(name: str, data: bytes) -> str:
    files[name] = data
    return name


def b64(b: bytes) -> dict:
    return {"base64": base64.b64encode(b).decode()}


def err(code: str) -> dict:
    return {"error": {"kind": KIND[code], "code": code}}


def outcome(fn, *args, **kw):
    try:
        return fn(*args, **kw), None
    except SpecError as e:
        return None, e.code


def header_case(cid, desc, data, source, file=None, group="header"):
    got, code = outcome(spec_decode_header, data)
    if source == "oracle":
        o = ot.deserialize_header(data)
        assert code is None
        for a, b in [("root_offset", "root_directory_offset"), ("tile_data_length", "tile_data_length"),
                     ("leaf_directory_offset", "leaf_directories_offset"), ("max_zoom", "max_zoom")]:
            assert str(o[a]) == str(got[b]), (cid, a)
        assert abs(o["min_lon_e7"] / 1e7 - got["bounds"]["min_lon"]) < 1e-12
    inp = {"file": put(file, data)} if file else b64(data)
    add({"id": cid, "op": "decode_header", "level": "core", "group": group, "description": desc,
         "input": inp, "expect": err(code) if code else {"value": got},
         "compare": "exact" if code else "float_tol", "tolerance": None if code else 1e-9, "source": source})


def directory_case(cid, desc, raw, source, max_entries=None, file=None):
    kw = {"max_entries": max_entries} if max_entries is not None else {}
    got, code = outcome(spec_decode_directory, raw, **kw)
    if source == "oracle":
        o = ot.deserialize_directory(gzip.compress(raw, mtime=0))
        assert code is None and [(e.tile_id, e.offset, e.length, e.run_length) for e in o] == \
            [(e.tile_id, e.offset, e.length, e.run_length) for e in got], cid
    inp = {"file": put(file, raw)} if file else b64(raw)
    add({"id": cid, "op": "decode_directory", "level": "core", "group": "directory", "description": desc,
         "input": inp, "options": {"max_directory_entries": max_entries} if max_entries is not None else None,
         "expect": err(code) if code else {"value": [e.json() for e in got]}, "compare": "exact", "source": source})


def build() -> None:
    small, leaves = small_archive(), leaves_archive()
    hs, hl = ot.deserialize_header(small), ot.deserialize_header(leaves)
    assert hs["leaf_directory_length"] == 0 and hl["leaf_directory_length"] > 0, "archive shapes changed"
    put("archives/small.pmtiles", small)
    put("archives/leaves.pmtiles", leaves)
    small_none = put("archives/small-uncompressed.pmtiles", recompress_internal(small, 1))
    small_unknown = put("archives/small-unknown-compression.pmtiles", recompress_internal(small, 7))

    # --- decode_header
    header_case("header.small", "Oracle-written archive: gzip internal, clustered, NYC bounds",
                small[:127], "oracle", file="header/small.bin")
    header_case("header.leaves", "Archive with leaf directories", leaves[:127], "oracle", file="header/leaves.bin")
    header_case("header.trailing_bytes", "Bytes after 127 are ignored", small[:200], "oracle")
    unknown = bytearray(small[:127]); unknown[98] = 9; unknown[99] = 42; unknown[72:96] = bytes(24)
    header_case("header.unknown_enums_and_counts", "Unknown enum raw values are kept; zero counts decode as absent (A1)",
                bytes(unknown), "spec")
    header_case("header.error.truncated", "126 bytes: truncation is checked before magic", small[:126], "spec", group="header.error")
    header_case("header.error.truncated_bad_magic", "12 bytes of garbage: still truncated, not bad_magic",
                b"NOPEs\x00\x03" + bytes(5), "spec", group="header.error")
    bad = bytearray(small[:127]); bad[0:7] = b"PMTilez"
    header_case("header.error.bad_magic", "Magic is not 'PMTiles'", bytes(bad), "spec", group="header.error")
    v2 = bytearray(small[:127]); v2[7] = 2
    header_case("header.error.version_2", "Spec version byte 2", bytes(v2), "spec", group="header.error")

    # --- decode_directory (input is already decompressed: D-001)
    root_small = gzip.decompress(small[hs["root_offset"]:hs["root_offset"] + hs["root_length"]])
    root_leaves = gzip.decompress(leaves[hl["root_offset"]:hl["root_offset"] + hl["root_length"]])
    first_leaf_entry = spec_decode_directory(root_leaves)[0]
    leaf0 = gzip.decompress(leaves[hl["leaf_directory_offset"] + first_leaf_entry.offset:
                                   hl["leaf_directory_offset"] + first_leaf_entry.offset + first_leaf_entry.length])
    directory_case("directory.small_root", "Root directory with a run_length > 1 entry", root_small, "oracle")
    directory_case("directory.leaves_root", "Root of leaf pointers (run_length 0)", root_leaves, "oracle")
    directory_case("directory.leaf", "First leaf directory", leaf0, "oracle", file="directory/leaf0.bin")
    directory_case("directory.empty", "Zero entries", b"\x00", "spec")
    directory_case("directory.trailing_bytes", "Bytes after the last offset are ignored (A2)", root_small + b"\xff\xff", "spec")
    explicit = bytes([2, 5, 1, 1, 1, 10, 20, 1, 31])  # 2 entries, ids 5,6; offsets 0 and 30 (a gap, so stored explicitly)
    directory_case("directory.explicit_offsets", "Non-contiguous offsets stored explicitly (offset + 1)", explicit, "spec")
    directory_case("directory.error.truncated", "Ends inside the offsets", root_small[:-1] if root_small[-1] < 0x80 else root_small[:-2], "spec")
    directory_case("directory.error.varint_overflow", "A varint longer than 64 bits", b"\xff" * 10 + b"\x01", "spec")
    directory_case("directory.error.duplicate_tile_id", "Tile ids must strictly increase", bytes([2, 5, 0, 1, 1, 1, 1, 1, 0]), "spec")
    directory_case("directory.error.first_offset_zero", "Offset 0 (\"continue\") on the first entry", bytes([1, 5, 1, 1, 0]), "spec")
    directory_case("directory.error.too_many_entries", "Count above max_directory_entries, checked before reading entries",
                   bytes([3, 1, 1, 1]), "spec", max_entries=2)

    # --- tile ids (oracle; boundaries spec)
    coords = [(0, 0, 0), (1, 0, 0), (1, 0, 1), (1, 1, 1), (1, 1, 0), (2, 0, 0), (3, 0, 0),
              (12, 3423, 1763), (14, 4825, 6156), (20, 309000, 394000), (31, 0, 0), (31, 2**31 - 1, 2**31 - 1)]
    for z, x, y in coords:
        tid = spec_zxy_to_tile_id(z, x, y)
        assert tid == ot.zxy_to_tileid(z, x, y) and ot.tileid_to_zxy(tid) == (z, x, y)
        add({"id": f"tile_id.zxy.{z}_{x}_{y}", "op": "zxy_to_tile_id", "level": "core", "group": "tile_id",
             "input": {"value": {"z": z, "x": x, "y": y}}, "expect": {"value": u64_json(tid)},
             "compare": "exact", "source": "oracle"})
        add({"id": f"tile_id.inverse.{z}_{x}_{y}", "op": "tile_id_to_zxy", "level": "core", "group": "tile_id",
             "input": {"value": u64_json(tid)}, "expect": {"value": {"x": x, "y": y, "z": z}},
             "compare": "json_equal", "source": "oracle"})
    for cid, z, x, y, code in [("tile_id.error.zoom_32", 32, 0, 0, "pmtiles.invalid_zoom"),
                               ("tile_id.error.x_out_of_range", 3, 8, 0, "pmtiles.tile_out_of_range"),
                               ("tile_id.error.y_out_of_range", 0, 0, 1, "pmtiles.tile_out_of_range")]:
        assert outcome(spec_zxy_to_tile_id, z, x, y)[1] == code
        add({"id": cid, "op": "zxy_to_tile_id", "level": "core", "group": "tile_id.error",
             "input": {"value": {"z": z, "x": x, "y": y}}, "expect": err(code), "compare": "exact", "source": "spec"})
    assert outcome(spec_tile_id_to_zxy, MAX_TILE_ID + 1)[1] == "pmtiles.invalid_zoom"
    add({"id": "tile_id.inverse.last", "op": "tile_id_to_zxy", "level": "core", "group": "tile_id",
         "description": "The last valid tile id (zoom 31)", "input": {"value": u64_json(MAX_TILE_ID)},
         "expect": {"value": dict(zip("zxy", spec_tile_id_to_zxy(MAX_TILE_ID)))}, "compare": "json_equal", "source": "spec"})
    add({"id": "tile_id.error.beyond_zoom_31", "op": "tile_id_to_zxy", "level": "core", "group": "tile_id.error",
         "input": {"value": u64_json(MAX_TILE_ID + 1)}, "expect": err("pmtiles.invalid_zoom"),
         "compare": "exact", "source": "spec"})

    # --- find_entry (oracle cross-checked)
    small_entries = spec_decode_directory(root_small)
    run = next(e for e in small_entries if e.run_length > 1)
    leaf_ptrs = spec_decode_directory(root_leaves)
    for cid, entries, tid, desc in [
        ("find.exact", small_entries, small_entries[3].tile_id, "Exact tile id"),
        ("find.in_run", small_entries, run.tile_id + run.run_length - 1, "Last id covered by a run_length > 1 entry"),
        ("find.after_run", small_entries, run.tile_id + run.run_length, "First id after a run: next entry or absent"),
        ("find.absent_gap", small_entries, ot.zxy_to_tileid(3, 7, 7), "The tile left out of the archive"),
        ("find.before_first", small_entries[1:], 0, "Below the first entry"),
        ("find.leaf_pointer", leaf_ptrs, leaf_ptrs[1].tile_id + 5, "A leaf pointer covers every id up to the next entry"),
        ("find.empty", [], 7, "Empty directory"),
    ]:
        got = spec_find_entry(entries, tid)
        o = ot.find_tile([ot.Entry(e.tile_id, e.offset, e.length, e.run_length) for e in entries], tid)
        assert (got is None) == (o is None) and (got is None or got.tile_id == o.tile_id), cid
        add({"id": cid, "op": "find_entry", "level": "core", "group": "find", "description": desc,
             "input": {"value": {"entries": [e.json() for e in entries], "tile_id": u64_json(tid)}},
             "expect": {"value": got.json() if got else None}, "compare": "json_equal", "source": "oracle"})

    # --- io: get_tile and read_metadata on the archive files
    def tile_case(cid, archive_name, archive, zxy, desc, source="oracle"):
        got, code = outcome(spec_get_tile, archive, *zxy)
        if source == "oracle":
            o = Reader(MemorySource(archive)).get(*zxy)
            assert code is None and got == o, cid
        add({"id": cid, "op": "get_tile", "level": "io", "group": "get_tile", "description": desc,
             "input": {"file": archive_name, "args": {"coord": dict(zip("zxy", zxy))}},
             "expect": err(code) if code else ({"value": None} if got is None else b64(got)),
             "compare": "exact" if code or got is None else "bytes", "source": source})

    tile_case("get_tile.small.root", "archives/small.pmtiles", small, (0, 0, 0), "Zoom 0")
    tile_case("get_tile.small.z2", "archives/small.pmtiles", small, (2, 1, 3), "A tile in the root directory")
    rz = ot.tileid_to_zxy(run.tile_id + 1)
    tile_case("get_tile.small.run", "archives/small.pmtiles", small, rz, "A tile served by a run_length > 1 entry")
    tile_case("get_tile.small.absent", "archives/small.pmtiles", small, (3, 7, 7), "Absent tile returns nothing")
    tile_case("get_tile.small.above_max_zoom", "archives/small.pmtiles", small, (5, 0, 0), "Zoom above the archive's max")
    tile_case("get_tile.leaves.first", "archives/leaves.pmtiles", leaves, (0, 0, 0), "Through a leaf directory")
    tile_case("get_tile.leaves.deep", "archives/leaves.pmtiles", leaves, (7, 100, 77), "Max zoom, in a later leaf")
    tile_case("get_tile.leaves.last", "archives/leaves.pmtiles", leaves, (7, 127, 127), "Last tile of the last leaf")
    tile_case("get_tile.uncompressed", small_none, files[small_none], (2, 1, 3),
              "Internal compression 'none'", source="spec")
    tile_case("get_tile.error.unknown_compression", small_unknown, files[small_unknown], (2, 1, 3),
              "Internal compression raw value 7 is undefined, so no port can decode it", source="spec")

    def meta_case(cid, name, archive, desc, source="oracle"):
        got, code = outcome(spec_read_metadata, archive)
        if source == "oracle":
            assert code is None and json.loads(got) == Reader(MemorySource(archive)).metadata(), cid
        add({"id": cid, "op": "read_metadata", "level": "io", "group": "metadata", "description": desc,
             "input": {"file": name}, "expect": err(code) if code else {"value": got},
             "compare": "exact", "source": source})

    meta_case("metadata.small", "archives/small.pmtiles", small, "gzip-compressed JSON")
    meta_case("metadata.leaves", "archives/leaves.pmtiles", leaves, "Archive with leaves")
    meta_case("metadata.uncompressed", small_none, files[small_none], "Internal compression 'none'", source="spec")


def main() -> None:
    build()
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    for name, data in files.items():
        p = CASES / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    manifest = {"capability": "pmtiles", "spec_version": SPEC_VERSION, "oracle": ORACLE,
                "generated_at": GENERATED_AT, "cases": cases}
    (ROOT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n")
    by_source = {s: sum(c["source"] == s for c in cases) for s in ("oracle", "spec")}
    by_level = {lv: sum(c["level"] == lv for c in cases) for lv in ("core", "io")}
    print(f"wrote manifest.json: {len(cases)} cases ({by_source['oracle']} oracle, {by_source['spec']} spec; "
          f"core {by_level['core']}, io {by_level['io']}) and {len(files)} case files")


if __name__ == "__main__":
    main()

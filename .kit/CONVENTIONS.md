# Conventions

> Shared by every library in this family. This file is vendored into each library repo as `.kit/CONVENTIONS.md`. Don't edit it there; changes come from upstream with a new kit version.

A library's `spec/SPEC.md` may override a convention only with an entry in its `DECISIONS.md`, listed under `conventions_overrides` in `spec/capability.yaml`.

## 1. Data conventions

| Topic | Convention |
|---|---|
| Coordinates | WGS84 degrees, order **(lon, lat)** as in GeoJSON, MVT and most libraries. Field names `lon`, `lat`, never `x`/`y` for geographic values. |
| Projected / tile space | `x`, `y` (and `z` for zoom), integers where the format is integer. |
| Units | SI. Distances in meters, durations in nanoseconds, angles in degrees unless the format says otherwise. |
| Time | `timestamp` = UTC, nanosecond precision. Text form RFC 3339 with `Z`. Never local time in core. |
| Text | UTF-8 everywhere. Invalid UTF-8 in input is an `invalid_input` error unless the spec allows lossy decoding. |
| Bytes | Format-defined endianness; otherwise little-endian. Byte offsets and lengths are `u64`. |
| Indices | Zero-based, half-open ranges `[start, end)`. |
| Optionality | Absent and empty are different. Use the language's optional type; never sentinel values (`-1`, `""`). |
| Floats | `f64` unless the format stores `f32`. Fixture comparisons use the tolerance declared per case. |
| Rounding | Float → integer rounding is **round half away from zero** (`2.5 → 3`, `-2.5 → -3`) unless the format defines its own rule. The rule applies to the `f64` value exactly as computed; the spec states how that value is computed (e.g. `x * 10^p`). Never use the language default without checking it: several round half to even. |
| Enums | Unknown values from input are preserved as `unknown(raw)` when the format allows extension, not dropped or rejected. |

## 2. Error model

Every library uses the same error **kinds**. Ports map them to native errors but keep the kind and the stable `code` string.

| Kind | Meaning | Example |
|---|---|---|
| `invalid_input` | Input violates the format | Bad magic bytes, truncated varint |
| `unsupported` | Valid, but uses a feature this port doesn't implement | Unknown compression type |
| `limit_exceeded` | Input exceeds a configured limit | Directory larger than its limit |
| `not_found` | Requested item doesn't exist | Tile not in archive |
| `io` | Source or sink failure (io layer only) | HTTP 500, file missing |
| `internal` | Bug in the library | Invariant violated |

- Each error carries `kind`, a stable machine `code` (`<library>.<name>`, listed in `capability.yaml`), a human message, and the byte offset when known.
- `not_found` is an error only when absence is exceptional; when absence is normal the operation returns an optional (the spec says which).
- The core layer never produces `io`.
- Conformance fixtures assert **kind and code**, never message text.

## 3. Layers

Every port has three layers, depending in this direction only: `integrations → io → core`.

| Layer | Contains | Must not |
|---|---|---|
| **core** | Types; parse/encode/compute on in-memory bytes and values; limits; errors | Do I/O, read clocks or environment, spawn threads, log, hold global state |
| **io** | Sources and sinks (file, memory-map, HTTP range, streams); async where idiomatic | Contain format logic |
| **integrations** | Platform adapters (map views, UI toolkits, plotting) | Be required: always a separate module |

## 4. Conformance

- `conformance/manifest.json` lists every case (schema: `.kit/schemas/fixture.schema.json`). Cases are generated from a pinned reference implementation named in `capability.yaml`. Cases that implementation can't produce (inputs it rejects badly, crashes on, or gets wrong) are written from the spec and marked `"source": "spec"`.
- A case's `options` may set **limits** as well as tunables (`{"max_points": 2}`), so limit cases stay small. Every port's options value accepts the limits.
- Inputs that aren't valid UTF-8 text use the `{"base64": …}` payload; runners decode it and pass the raw bytes to the operation.
- Error cases assert `offset` wherever the spec defines one; runners compare it when present.
- Each port has one runner that loads the manifest, runs every case at the levels it claims, converts results to canonical JSON (§5) and compares using the case's `compare` mode.
- A port claims a level (`core`, `io`, `full`) only when every case at that level passes.
- Validate spec and fixtures with `uv run .kit/validate.py .` (or `python .kit/validate.py .` after `pip install pyyaml jsonschema`).

`capability.yaml` describes every field and parameter with these type names. Ports map them as below; fixtures encode them as canonical JSON.

## 5. Canonical types

### Vocabulary

| Canonical | Meaning |
|---|---|
| `bool` | true / false |
| `i32`, `i64` | Signed integers |
| `u8`, `u32`, `u64` | Unsigned integers |
| `f32`, `f64` | IEEE 754 floats |
| `string` | UTF-8 text |
| `bytes` | Owned byte sequence |
| `bytes_view` | Borrowed bytes (may alias the input; copy if the language can't express it safely) |
| `list<T>` | Ordered sequence |
| `map<string, T>` | String-keyed map; iteration order is not guaranteed unless the spec says `ordered_map` |
| `optional<T>` | Present or absent |
| `timestamp` | UTC instant, nanosecond precision |
| `duration` | Signed span, nanoseconds |
| `lonlat` | `{lon: f64, lat: f64}` in WGS84 degrees |
| `bbox` | `{min_lon, min_lat, max_lon, max_lat: f64}` |
| `<StructName>` | A struct defined in `capability.yaml` |
| `<EnumName>` | An enum defined in `capability.yaml` (may be `open`: preserves unknown raw values) |

### Mapping to languages

| Canonical | Python | Swift | Go | Kotlin | Rust | Nim | Zig | Julia |
|---|---|---|---|---|---|---|---|---|
| `bool` | `bool` | `Bool` | `bool` | `Boolean` | `bool` | `bool` | `bool` | `Bool` |
| `i32` | `int` | `Int32` | `int32` | `Int` | `i32` | `int32` | `i32` | `Int32` |
| `i64` | `int` | `Int64` | `int64` | `Long` | `i64` | `int64` | `i64` | `Int64` |
| `u8` | `int` | `UInt8` | `uint8` | `UByte` | `u8` | `uint8` | `u8` | `UInt8` |
| `u32` | `int` | `UInt32` | `uint32` | `UInt` | `u32` | `uint32` | `u32` | `UInt32` |
| `u64` | `int` | `UInt64` | `uint64` | `ULong` | `u64` | `uint64` | `u64` | `UInt64` |
| `f32` | `float` | `Float` | `float32` | `Float` | `f32` | `float32` | `f32` | `Float32` |
| `f64` | `float` | `Double` | `float64` | `Double` | `f64` | `float64` | `f64` | `Float64` |
| `string` | `str` | `String` | `string` | `String` | `String` / `&str` | `string` | `[]const u8` | `String` |
| `bytes` | `bytes` | `[UInt8]` | `[]byte` | `ByteArray` | `Vec<u8>` | `seq[byte]` | `[]u8` (caller frees) | `Vector{UInt8}` |
| `bytes_view` | `memoryview` | `ArraySlice<UInt8>` | `[]byte` (aliases) | `ByteArray` (copy) | `&[u8]` | `openArray[byte]` | `[]const u8` | `view` / `SubArray` |
| `list<T>` | `list[T]` / `Sequence[T]` | `[T]` | `[]T` | `List<T>` | `Vec<T>` | `seq[T]` | `[]T` | `Vector{T}` |
| `map<string,T>` | `dict[str, T]` | `[String: T]` | `map[string]T` | `Map<String, T>` | `BTreeMap<String, T>` | `Table[string, T]` | `std.StringHashMap(T)` | `Dict{String,T}` |
| `optional<T>` | `T \| None` | `T?` | `*T` or `(T, bool)` | `T?` | `Option<T>` | `Option[T]` | `?T` | `Union{T,Nothing}` |
| `timestamp` | `int` ns + `datetime` helper | `Timestamp` (Int64 ns) + `Date` helper in integrations | `time.Time` (UTC) | `kotlin.time.Instant` | `Timestamp(i64)` newtype | `distinct int64` ns | `i64` ns | `Int64` ns + `Dates` helper |
| `duration` | `int` ns + `timedelta` helper | `Duration` | `time.Duration` | `kotlin.time.Duration` | `core::time::Duration` | `Duration` (std/times) | `i64` ns | `Dates.Nanosecond` |
| struct | `@dataclass(frozen=True, slots=True)` | `struct` (`Sendable`, `Equatable`) | `struct` | `data class` | `struct` (`Debug, Clone, PartialEq`) | `object` | `struct` | `struct` (immutable) |
| enum (closed) | `enum.Enum` | `enum` | typed `const` | `enum class` | `enum` | `enum` | `enum` | `@enum` |
| enum (open) | `IntEnum` + `Unknown(raw)` | `enum` with `case unknown(raw)` | typed `const` (any value) | `sealed` + `Unknown(raw)` | `#[non_exhaustive] enum` + `Unknown(raw)` | `object` with kind + raw | `enum(uN) { …, _ }` | `struct` with raw value |

Notes:
- Rust uses `BTreeMap` so map output is deterministic. Elsewhere, sort keys when serializing.
- Swift's `Duration` is in the standard library; keep `Date` out of core because core doesn't import Foundation.
- Python's `datetime` can't hold nanoseconds, so core uses `int` ns and offers a `datetime` helper.

### Canonical JSON (fixtures)

Expected outputs and inline inputs in `conformance/manifest.json` use these rules, so every runner compares the same thing:

| Type | JSON form |
|---|---|
| Integers within ±2^53 | number |
| Integers beyond ±2^53 (`u64`, `i64`) | decimal string |
| Floats | number; `NaN` / `Infinity` as strings `"NaN"`, `"Infinity"`, `"-Infinity"` |
| `string` | string |
| `bytes`, `bytes_view` | `{"base64": "…"}` |
| `timestamp` | string, RFC 3339 UTC with 9 fractional digits: `"2026-10-04T12:00:00.000000000Z"` |
| `duration` | integer nanoseconds (string if beyond ±2^53) |
| `optional<T>` absent | `null` |
| struct | object, keys in canonical `snake_case` |
| enum | `snake_case` name string; unknown values `{"unknown": raw}` |
| `map` | object with keys sorted |
| `list` | array |
| error | `{"error": {"kind": "invalid_input", "code": "pmtiles.bad_magic"}}` |

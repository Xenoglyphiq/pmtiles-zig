//! Reference timings for the pmtiles spec: the Rust `pmtiles` crate, get_tile for every
//! coordinate in bench/coords.txt from an in-memory source. Method (shared by every port,
//! see bench/README.md): load once; 3 warm-up passes, then 15 timed passes over all
//! 10,000 lookups; report the median and min per pass. The checksum (total bytes of the
//! returned tiles) must match bench/README.md.
//!
//! Run from the repo root:  cargo run --release --manifest-path bench/rust/Cargo.toml

use std::time::Instant;

use bytes::Bytes;
use pmtiles::{AsyncBackend, AsyncPmTilesReader, BackendResponse, PmtResult, TileCoord};

const WARMUP: usize = 3;
const RUNS: usize = 15;
const CHECKSUM: usize = 998_434;

/// The crate has no in-memory backend, so this is one: slices of a `Bytes` buffer.
struct MemoryBackend(Bytes);

impl AsyncBackend for MemoryBackend {
    async fn read(&self, offset: usize, length: usize) -> PmtResult<BackendResponse> {
        let start = offset.min(self.0.len());
        let end = offset.saturating_add(length).min(self.0.len());
        Ok(BackendResponse::new(self.0.slice(start..end)))
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| "bench".into());
    let archive = Bytes::from(std::fs::read(format!("{dir}/bench.pmtiles")).expect("read bench.pmtiles"));
    let coords: Vec<TileCoord> = std::fs::read_to_string(format!("{dir}/coords.txt"))
        .expect("read coords.txt")
        .lines()
        .map(|l| {
            let p: Vec<u32> = l.split('/').map(|n| n.parse().unwrap()).collect();
            TileCoord::new(p[0] as u8, p[1], p[2]).unwrap()
        })
        .collect();
    let reader = AsyncPmTilesReader::try_from_source(MemoryBackend(archive)).await.expect("open archive");

    let mut ms = Vec::with_capacity(RUNS);
    for run in 0..WARMUP + RUNS {
        let start = Instant::now();
        let mut total = 0usize;
        for &c in &coords {
            if let Some(tile) = reader.get_tile(c).await.expect("get_tile") {
                total += tile.len();
            }
        }
        let elapsed = start.elapsed().as_secs_f64() * 1e3;
        assert_eq!(total, CHECKSUM, "checksum mismatch: wrong bytes returned");
        if run >= WARMUP {
            ms.push(elapsed);
        }
    }
    ms.sort_by(f64::total_cmp);
    println!(
        "rust pmtiles 0.24.1 ({} lookups): get_tile pass median {:.3} ms (min {:.3}), checksum {CHECKSUM} ok",
        coords.len(),
        ms[RUNS / 2],
        ms[0]
    );
}

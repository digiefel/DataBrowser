//! Invisible level-of-detail (LOD) decimation for 10M-point lines and scatter plots.
//!
//! For 2D monotonic-X `Lines`, builds a block-based M4 pyramid storing `(first, min_y, max_y, last)`
//! per bucket so zoomed-out views preserve exact vertical extrema per pixel column in <1 ms while
//! zooming in transitions seamlessly to raw points.

#[derive(Debug, Clone)]
pub struct LineLodLevel {
    pub block_size: usize,
    /// Packed `[x, y, z]` vertices (`len = 3 * num_points`).
    pub positions: Vec<f32>,
    /// Original 0-based vertex index for each LOD point so picking and colors stay exact.
    pub original_indices: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct LineLod {
    pub is_monotonic_x: bool,
    pub raw_point_count: usize,
    pub levels: Vec<LineLodLevel>,
}

#[derive(Debug, Clone)]
pub struct LodSlice<'a> {
    pub positions: &'a [f32],
    pub original_indices: &'a [u32],
}

const MONOTONIC_LOD_THRESHOLD: usize = 16_384;
const GENERIC_LOD_THRESHOLD: usize = 65_536;

impl LineLod {
    /// Build an invisible LOD hierarchy from raw `vec3<f32>` positions.
    pub fn build(raw_positions: &[f32]) -> Self {
        let count = raw_positions.len() / 3;
        if count <= MONOTONIC_LOD_THRESHOLD {
            return Self {
                is_monotonic_x: false,
                raw_point_count: count,
                levels: Vec::new(),
            };
        }

        let monotonic = is_non_decreasing_x(raw_positions);
        if !monotonic && count <= GENERIC_LOD_THRESHOLD {
            return Self {
                is_monotonic_x: false,
                raw_point_count: count,
                levels: Vec::new(),
            };
        }

        let mut levels = Vec::new();
        if monotonic {
            let mut block_size = 16usize;
            while count / block_size >= 1024 {
                levels.push(build_m4_level(raw_positions, block_size));
                block_size *= 4;
            }
        } else {
            let mut stride = 4usize;
            while count / stride >= 4096 {
                levels.push(build_strided_level(raw_positions, stride));
                stride *= 4;
            }
        }

        Self {
            is_monotonic_x: monotonic,
            raw_point_count: count,
            levels,
        }
    }

    /// Choose the optimal visible slice `(start_pt, end_pt)` for the current viewport and X limits.
    /// Returns `None` when raw points should be rendered directly (zoomed in or small plot).
    pub fn select_slice(
        &self,
        xmin: f64,
        xmax: f64,
        viewport_width_px: f32,
        is_2d: bool,
    ) -> Option<(usize, LodSlice<'_>)> {
        let target_points = (viewport_width_px.max(64.0) as usize) * 4;
        if !is_2d || !self.is_monotonic_x {
            if self.levels.is_empty() || self.raw_point_count <= target_points * 2 {
                return None;
            }
            for level in self.levels.iter().rev() {
                let pts = level.original_indices.len();
                if pts >= target_points || level.block_size == self.levels.last().unwrap().block_size {
                    return Some((
                        0,
                        LodSlice {
                            positions: &level.positions,
                            original_indices: &level.original_indices,
                        },
                    ));
                }
            }
            return None;
        }

        // Check how many raw points lie inside [xmin, xmax] via binary search.
        // Note: callers pass raw positions when None is returned; slice bounds for raw are computed
        // via `raw_x_range` if desired. Here we check finest-to-coarsest LOD levels.
        let mut best: Option<(usize, LodSlice<'_>)> = None;
        for level in &self.levels {
            let (s, e) = x_range_in_slice(&level.positions, xmin as f32, xmax as f32);
            let visible_pts = e.saturating_sub(s);
            let slice = LodSlice {
                positions: &level.positions[s * 3..e * 3],
                original_indices: &level.original_indices[s..e],
            };
            best = Some((s, slice));
            if visible_pts <= target_points * 2 {
                // If even this finest LOD has <= target_points, check whether raw points also fit.
                let estimated_raw = visible_pts * (level.block_size / 4).max(1);
                if estimated_raw <= target_points * 2 {
                    return None;
                }
                return best;
            }
        }
        best
    }
}

/// Compute the visible slice `[start, end)` for raw monotonic-X `positions`.
pub fn raw_x_range(raw_positions: &[f32], xmin: f32, xmax: f32) -> (usize, usize) {
    x_range_in_slice(raw_positions, xmin, xmax)
}

fn is_non_decreasing_x(positions: &[f32]) -> bool {
    let count = positions.len() / 3;
    if count < 2 {
        return true;
    }
    let mut prev = positions[0];
    if !prev.is_finite() {
        return false;
    }
    for i in 1..count {
        let x = positions[i * 3];
        if !x.is_finite() || x < prev {
            return false;
        }
        prev = x;
    }
    true
}

fn build_m4_level(raw: &[f32], block_size: usize) -> LineLodLevel {
    let count = raw.len() / 3;
    let num_blocks = count.div_ceil(block_size);
    let mut positions = Vec::with_capacity(num_blocks * 4 * 3);
    let mut original_indices = Vec::with_capacity(num_blocks * 4);

    for b in 0..num_blocks {
        let start = b * block_size;
        let end = ((b + 1) * block_size).min(count);
        if start >= end {
            continue;
        }
        let mut min_idx = start;
        let mut max_idx = start;
        let mut min_y = raw[start * 3 + 1];
        let mut max_y = min_y;
        let mut any_finite = min_y.is_finite();

        for i in (start + 1)..end {
            let y = raw[i * 3 + 1];
            if y.is_finite() {
                if !any_finite || y < min_y {
                    min_y = y;
                    min_idx = i;
                }
                if !any_finite || y > max_y {
                    max_y = y;
                    max_idx = i;
                }
                any_finite = true;
            }
        }

        let last = end - 1;
        let mut bucket = [start, min_idx, max_idx, last];
        bucket.sort_unstable();
        let mut prev = usize::MAX;
        for idx in bucket {
            if idx != prev {
                positions.push(raw[idx * 3]);
                positions.push(raw[idx * 3 + 1]);
                positions.push(raw[idx * 3 + 2]);
                original_indices.push(idx as u32);
                prev = idx;
            }
        }
    }

    LineLodLevel {
        block_size,
        positions,
        original_indices,
    }
}

fn build_strided_level(raw: &[f32], stride: usize) -> LineLodLevel {
    let count = raw.len() / 3;
    let mut positions = Vec::with_capacity((count / stride + 2) * 3);
    let mut original_indices = Vec::with_capacity(count / stride + 2);
    let mut i = 0;
    while i < count {
        positions.push(raw[i * 3]);
        positions.push(raw[i * 3 + 1]);
        positions.push(raw[i * 3 + 2]);
        original_indices.push(i as u32);
        i += stride;
    }
    if count > 0 && original_indices.last().copied() != Some((count - 1) as u32) {
        let last = count - 1;
        positions.push(raw[last * 3]);
        positions.push(raw[last * 3 + 1]);
        positions.push(raw[last * 3 + 2]);
        original_indices.push(last as u32);
    }
    LineLodLevel {
        block_size: stride,
        positions,
        original_indices,
    }
}

fn x_range_in_slice(positions: &[f32], xmin: f32, xmax: f32) -> (usize, usize) {
    let count = positions.len() / 3;
    if count == 0 {
        return (0, 0);
    }
    let lo_x = xmin.min(xmax);
    let hi_x = xmin.max(xmax);

    // Lower bound: first index with x >= lo_x, minus 1 for connecting segment.
    let mut lo = 0usize;
    let mut hi = count;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if positions[mid * 3] < lo_x {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let start = lo.saturating_sub(1);

    // Upper bound: first index with x > hi_x, plus 1 for connecting segment.
    let mut lo2 = start;
    let mut hi2 = count;
    while lo2 < hi2 {
        let mid = lo2 + (hi2 - lo2) / 2;
        if positions[mid * 3] <= hi_x {
            lo2 = mid + 1;
        } else {
            hi2 = mid;
        }
    }
    let end = (lo2 + 1).min(count);
    (start, end)
}

/// Deterministic strided LOD for massive (>100k) scatter clouds.
#[derive(Debug, Clone)]
pub struct ScatterLod {
    pub raw_point_count: usize,
    pub levels: Vec<(usize, Vec<u32>)>,
}

const SCATTER_LOD_THRESHOLD: usize = 100_000;

impl ScatterLod {
    pub fn build(raw_positions: &[f32]) -> Self {
        let count = raw_positions.len() / 3;
        if count <= SCATTER_LOD_THRESHOLD {
            return Self {
                raw_point_count: count,
                levels: Vec::new(),
            };
        }
        let mut levels = Vec::new();
        let mut stride = 4usize;
        while count / stride >= 25_000 {
            let indices: Vec<u32> = (0..count).step_by(stride).map(|i| i as u32).collect();
            levels.push((stride, indices));
            stride *= 4;
        }
        Self {
            raw_point_count: count,
            levels,
        }
    }

    /// Select stride indices when zoomed out, or `None` to draw all points.
    pub fn select_indices(&self, zoomed_in_fraction: f64) -> Option<&[u32]> {
        if self.levels.is_empty() {
            return None;
        }
        let estimated_visible = (self.raw_point_count as f64) * zoomed_in_fraction.clamp(0.001, 1.0);
        if estimated_visible <= 200_000.0 {
            return None;
        }
        for (stride, indices) in &self.levels {
            if estimated_visible / (*stride as f64) <= 200_000.0 {
                return Some(indices);
            }
        }
        self.levels.last().map(|(_, idx)| idx.as_slice())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn m4_preserves_spike_extrema_and_is_fast_on_million_points() {
        let n = 1_000_000usize;
        let mut pos = Vec::with_capacity(n * 3);
        for i in 0..n {
            let x = i as f32 * 0.001;
            let y = if i == 500_123 {
                99.5
            } else if i == 500_124 {
                -88.5
            } else {
                (x * 0.1).sin()
            };
            pos.push(x);
            pos.push(y);
            pos.push(0.0);
        }
        let lod = LineLod::build(&pos);
        assert!(lod.is_monotonic_x);
        assert!(!lod.levels.is_empty());

        let t0 = Instant::now();
        let (_, slice) = lod.select_slice(0.0, 1000.0, 800.0, true).unwrap();
        let elapsed = t0.elapsed();
        assert!(elapsed.as_millis() < 5, "LOD select took {:?}", elapsed);
        assert!(slice.positions.len() / 3 <= 16_000);

        let mut max_y = f32::NEG_INFINITY;
        let mut min_y = f32::INFINITY;
        for chunk in slice.positions.chunks_exact(3) {
            max_y = max_y.max(chunk[1]);
            min_y = min_y.min(chunk[1]);
        }
        assert!((max_y - 99.5).abs() < 1e-4, "max_y={max_y}");
        assert!((min_y - (-88.5)).abs() < 1e-4, "min_y={min_y}");

        // Zoomed way in: falls back to raw points.
        assert!(lod.select_slice(500.0, 500.5, 800.0, true).is_none());
    }
}

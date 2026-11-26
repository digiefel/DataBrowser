//! Linear and log10 tick generation and number formatting for local 120 FPS axes.

use wgpu_makie_proto::AxisScale;

#[derive(Debug, Clone, PartialEq)]
pub struct GeneratedTicks {
    pub values: Vec<f64>,
    pub labels: Vec<String>,
}

/// Format a number cleanly: up to 4 significant digits, trailing `.0` stripped,
/// and compact scientific notation outside `[1e-3, 1e4)`.
pub fn format_tick_number(value: f64) -> String {
    if !value.is_finite() {
        return value.to_string();
    }
    if value == 0.0 {
        return "0".to_string();
    }
    let abs = value.abs();
    let exp = abs.log10().floor() as i32;
    if (-3..4).contains(&exp) {
        let decimals = (3 - exp).max(0) as usize;
        let factor = 10f64.powi(decimals as i32);
        let rounded = (value * factor).round() / factor;
        let mut s = format!("{rounded:.decimals$}");
        if s.contains('.') {
            while s.ends_with('0') {
                s.pop();
            }
            if s.ends_with('.') {
                s.pop();
            }
        }
        if s == "-0" {
            return "0".to_string();
        }
        s
    } else {
        let mantissa = value / 10f64.powi(exp);
        let rounded = (mantissa * 1000.0).round() / 1000.0;
        let mut m = format!("{rounded:.3}");
        if m.contains('.') {
            while m.ends_with('0') {
                m.pop();
            }
            if m.ends_with('.') {
                m.pop();
            }
        }
        format!("{m}e{exp}")
    }
}

/// Generate nice ticks for `[min_val, max_val]` under `scale`.
pub fn generate_ticks(
    min_val: f64,
    max_val: f64,
    scale: AxisScale,
    target_count: usize,
) -> GeneratedTicks {
    let lo = min_val.min(max_val);
    let hi = min_val.max(max_val);
    if !lo.is_finite() || !hi.is_finite() || (hi - lo).abs() <= f64::EPSILON * lo.abs().max(1.0) {
        return GeneratedTicks {
            values: vec![lo],
            labels: vec![format_tick_number(lo)],
        };
    }

    match scale {
        AxisScale::Log10 if lo > 0.0 && hi > 0.0 => generate_log10_ticks(lo, hi, target_count),
        _ => generate_linear_ticks(lo, hi, target_count.max(2)),
    }
}

fn nice_number(range: f64, round: bool) -> f64 {
    let exp = range.log10().floor();
    let frac = range / 10f64.powf(exp);
    let nice_frac = if round {
        if frac < 1.5 {
            1.0
        } else if frac < 3.0 {
            2.0
        } else if frac < 7.0 {
            5.0
        } else {
            10.0
        }
    } else if frac <= 1.0 {
        1.0
    } else if frac <= 2.0 {
        2.0
    } else if frac <= 5.0 {
        5.0
    } else {
        10.0
    };
    nice_frac * 10f64.powf(exp)
}

fn generate_linear_ticks(lo: f64, hi: f64, target_count: usize) -> GeneratedTicks {
    let range = nice_number(hi - lo, false);
    let step = nice_number(range / (target_count - 1) as f64, true);
    if step <= 0.0 || !step.is_finite() {
        return GeneratedTicks {
            values: vec![lo, hi],
            labels: vec![format_tick_number(lo), format_tick_number(hi)],
        };
    }
    let start = (lo / step).ceil() * step;
    let end = (hi / step).floor() * step;
    let mut values = Vec::new();
    let mut labels = Vec::new();
    let max_ticks = 64usize;
    let mut k = 0usize;
    while k < max_ticks {
        let v = start + (k as f64) * step;
        if v > end + step * 1e-6 {
            break;
        }
        let clean = if v.abs() < step * 1e-9 { 0.0 } else { v };
        if clean >= lo - step * 1e-6 && clean <= hi + step * 1e-6 {
            values.push(clean);
            labels.push(format_tick_number(clean));
        }
        k += 1;
    }
    GeneratedTicks { values, labels }
}

fn generate_log10_ticks(lo: f64, hi: f64, target_count: usize) -> GeneratedTicks {
    let e_lo = lo.log10().ceil() as i32;
    let e_hi = hi.log10().floor() as i32;
    let mut values = Vec::new();
    let mut labels = Vec::new();
    if e_hi >= e_lo {
        let span = (e_hi - e_lo) + 1;
        let stride = ((span as f64) / (target_count.max(2) as f64)).ceil().max(1.0) as i32;
        let mut e = e_lo;
        while e <= e_hi {
            let v = 10f64.powi(e);
            values.push(v);
            labels.push(format_tick_number(v));
            e += stride;
        }
    }
    if values.len() < 2 {
        return generate_linear_ticks(lo, hi, target_count.max(2));
    }
    GeneratedTicks { values, labels }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linear_ticks_cover_range_cleanly() {
        let t = generate_ticks(0.0, 10.0, AxisScale::Linear, 6);
        assert!(t.values.len() >= 5);
        assert!((t.values[0] - 0.0).abs() < 1e-9);
        assert!((*t.values.last().unwrap() - 10.0).abs() < 1e-9);
        assert_eq!(t.labels.first().unwrap(), "0");
    }

    #[test]
    fn log10_ticks_pick_powers_of_ten() {
        let t = generate_ticks(1e-2, 1e3, AxisScale::Log10, 6);
        assert!(t.values.len() >= 4);
        assert!((t.values[0] - 0.01).abs() < 1e-12);
        assert!((*t.values.last().unwrap() - 1000.0).abs() < 1e-9);
    }
}

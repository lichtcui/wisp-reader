use crate::cpu_info::get_hw_big_cores;
use lazy_static::lazy_static;
use std::path::Path;
use std::sync::RwLock;

use ort::{
    execution_providers::CPUExecutionProvider,
    session::{Session, builder::GraphOptimizationLevel},
};

use crate::error::GSVError;
lazy_static! {
    pub static ref BIG_CORES: Vec<(usize, u64)> =
        get_hw_big_cores().unwrap_or((0..8).map(|id| (id, 0)).collect());
}

/// Session tuning for mobile targets. HarmonyOS app processes cannot have
/// environment variables injected, so the host passes these through
/// `ttsInit`'s options JSON instead. `None` ⇒ P3/Mac defaults.
#[derive(Debug, Clone, Copy, Default)]
pub struct SessionTuning {
    pub intra_threads: Option<usize>,
    /// `false` ⇒ one shared pool instead of a per-session spinning pool.
    pub independent_pool: Option<bool>,
    pub spin: Option<bool>,
    pub inter_threads: Option<usize>,
}

static TUNING: RwLock<Option<SessionTuning>> = RwLock::new(None);

/// Override session tuning for every session created afterwards. Call before
/// building a `TTSModel`.
pub fn set_session_tuning(tuning: SessionTuning) {
    if let Ok(mut guard) = TUNING.write() {
        *guard = Some(tuning);
    }
}

fn tuning() -> SessionTuning {
    TUNING.read().ok().and_then(|g| *g).unwrap_or_default()
}

/// Intra-op thread count for the ONNX sessions.
///
/// Auto-detection reads `/sys/devices/system/cpu/*/cpufreq`, which HarmonyOS
/// does not expose to app processes; `BIG_CORES` then falls back to a hardcoded
/// 8 and the sessions oversubscribe a 4-core phone (spinning threads + cache
/// thrash ⇒ RTF > 1). `GSV_INTRA_THREADS` overrides it, which is how the P4
/// device runs are tuned.
fn intra_threads() -> usize {
    tuning()
        .intra_threads
        .or_else(|| env_usize("GSV_INTRA_THREADS"))
        .unwrap_or_else(|| BIG_CORES.len())
}

fn env_usize(key: &str) -> Option<usize> {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|n| *n > 0)
}

fn env_flag(key: &str) -> Option<bool> {
    std::env::var(key).ok().map(|v| {
        matches!(v.trim(), "1" | "true" | "TRUE" | "yes" | "on")
    })
}

pub fn create_onnx_cpu_session<P: AsRef<Path>>(path: P) -> Result<Session, GSVError> {
    let t = tuning();
    let independent_pool = t
        .independent_pool
        .or_else(|| env_flag("GSV_NO_INDEPENDENT_POOL").map(|no| !no))
        .unwrap_or(true);
    let spin = t.spin.or_else(|| env_flag("GSV_SPIN")).unwrap_or(true);
    let inter_threads = t
        .inter_threads
        .or_else(|| env_usize("GSV_INTER_THREADS"))
        .unwrap_or(1);

    let mut builder = Session::builder()?
        .with_execution_providers([CPUExecutionProvider::default()
            .with_arena_allocator(true)
            .build()])?
        .with_optimization_level(GraphOptimizationLevel::Level3)?
        .with_intra_threads(intra_threads())?;
    // HarmonyOS app processes see 12 CPUs but only 4 big cores; 8 sessions
    // each owning a spinning pool oversubscribes badly (P4 measured RTF 1.2–1.9
    // vs the 0.78–0.92 Mac baseline). These stay at the P3 defaults unless the
    // env flags are set, so Mac numbers are unaffected.
    if independent_pool {
        builder = builder.with_independent_thread_pool()?;
    }
    builder = builder.with_intra_op_spinning(spin)?;
    Ok(builder
        // 8 sessions otherwise each park a spinning inter-op pool; on device
        // that alone costs ~100 MB per session and adds scheduler noise.
        .with_inter_threads(inter_threads)?
        .with_prepacking(true)?
        .with_config_entry("session.enable_mem_reuse", "1")?
        .commit_from_file(path)?)
}

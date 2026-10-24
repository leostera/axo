//! Latency, error and event accounting shared by all load-test threads, and the final report.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::metrics::ProcessPeak;

/// Which latency budget a measured operation is held to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Class {
    /// Catalog reads and writes, terminal input and resize: must stay interactive.
    ControlPlane,
    /// Process spawn/stop and attach handshakes: bounded, but allowed more time.
    Lifecycle,
    /// Reported for comparison only.
    Informational,
}

fn class_of(operation: &str) -> Class {
    match operation {
        "axo.shell.create" | "axo.shell.close" | "attach.open" => Class::Lifecycle,
        "connect+session.list" => Class::Informational,
        _ => Class::ControlPlane,
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub control_plane_p99: Duration,
    pub lifecycle_p99: Duration,
}

#[derive(Default)]
struct Totals {
    latencies: BTreeMap<String, Vec<Duration>>,
    errors: BTreeMap<String, (u64, String)>,
    events: BTreeMap<(String, String), u64>,
}

#[derive(Clone, Default)]
pub struct Recorder(Arc<Mutex<Totals>>);

impl Recorder {
    pub fn latency(&self, operation: &str, elapsed: Duration) {
        let mut totals = self.0.lock().unwrap();
        totals
            .latencies
            .entry(operation.to_owned())
            .or_default()
            .push(elapsed);
    }

    pub fn error(&self, operation: &str, message: String) {
        let mut totals = self.0.lock().unwrap();
        totals
            .errors
            .entry(operation.to_owned())
            .or_insert((0, message))
            .0 += 1;
    }

    pub fn count_event(&self, subscriber: &str, kind: &str) {
        let mut totals = self.0.lock().unwrap();
        *totals
            .events
            .entry((subscriber.to_owned(), kind.to_owned()))
            .or_default() += 1;
    }

    pub fn report(&self, process: ProcessPeak, budget: Budget) -> Report {
        let totals = std::mem::take(&mut *self.0.lock().unwrap());
        let operations = totals
            .latencies
            .into_iter()
            .map(|(name, samples)| OperationReport::new(name, samples, budget))
            .collect();
        Report {
            operations,
            errors: totals.errors,
            events: totals.events,
            process,
        }
    }
}

pub struct OperationReport {
    name: String,
    count: usize,
    p50: Duration,
    p95: Duration,
    p99: Duration,
    max: Duration,
    budget: Option<Duration>,
}

impl OperationReport {
    fn new(name: String, mut samples: Vec<Duration>, budget: Budget) -> OperationReport {
        samples.sort_unstable();
        let at = |quantile: f64| {
            let index = ((samples.len() as f64 * quantile).ceil() as usize).saturating_sub(1);
            samples[index.min(samples.len() - 1)]
        };
        let budget = match class_of(&name) {
            Class::ControlPlane => Some(budget.control_plane_p99),
            Class::Lifecycle => Some(budget.lifecycle_p99),
            Class::Informational => None,
        };
        OperationReport {
            count: samples.len(),
            p50: at(0.50),
            p95: at(0.95),
            p99: at(0.99),
            max: *samples
                .last()
                .expect("an operation is only recorded with a sample"),
            budget,
            name,
        }
    }

    fn within_budget(&self) -> bool {
        self.budget.is_none_or(|budget| self.p99 <= budget)
    }
}

pub struct Report {
    operations: Vec<OperationReport>,
    errors: BTreeMap<String, (u64, String)>,
    events: BTreeMap<(String, String), u64>,
    process: ProcessPeak,
}

impl Report {
    pub fn passed(&self) -> bool {
        self.errors.is_empty()
            && !self.operations.is_empty()
            && self.operations.iter().all(OperationReport::within_budget)
    }
}

fn ms(duration: Duration) -> String {
    format!("{:.2}", duration.as_secs_f64() * 1000.0)
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "{:<24} {:>7} {:>8} {:>8} {:>8} {:>8} {:>8}  verdict",
            "operation", "count", "p50 ms", "p95 ms", "p99 ms", "max ms", "budget"
        )?;
        for op in &self.operations {
            let budget = op.budget.map_or("-".to_owned(), ms);
            let verdict = if op.within_budget() { "ok" } else { "OVER" };
            writeln!(
                f,
                "{:<24} {:>7} {:>8} {:>8} {:>8} {:>8} {:>8}  {verdict}",
                op.name,
                op.count,
                ms(op.p50),
                ms(op.p95),
                ms(op.p99),
                ms(op.max),
                budget
            )?;
        }
        writeln!(f, "events:")?;
        for ((subscriber, kind), count) in &self.events {
            writeln!(f, "  {subscriber:<8} {kind:<24} {count}")?;
        }
        writeln!(
            f,
            "axod peak: threads={} fds={} rss_mib={:.1}",
            self.process.threads,
            self.process.descriptors,
            self.process.resident_bytes as f64 / 1048576.0
        )?;
        for (operation, (count, first)) in &self.errors {
            writeln!(f, "ERROR {operation}: {count}x, first: {first}")?;
        }
        writeln!(f, "result: {}", if self.passed() { "PASS" } else { "FAIL" })
    }
}

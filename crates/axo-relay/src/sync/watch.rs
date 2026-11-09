//! What the file system says about open Sessions' transcripts (RFD0037,
//! `specs/sessions/upload-wakes.ts`): a change to one, or its creation while it does not exist
//! yet, wakes the uploader. FSEvents through `notify`, one stream for every transcript's
//! directory, reported to the uploader's `select!` through a tokio `Notify`.
//!
//! Directories are watched, not files: a transcript replaced at its path (renamed over) or
//! created later is still in the same directory, so nothing needs registering again. Events on
//! other files there are dropped. A directory that does not exist yet is stood in for by its
//! nearest existing ancestor, watched recursively, until the next `watch` finds it.
//!
//! The uploader watches before it reads, and `notify` starts its stream before `watch` returns,
//! so a change after the read is always seen. Adding a directory restarts the stream; a change
//! during the restart is before the read that follows, so it is read anyway. A stream that
//! starts also reports changes from just before it did: a wake with nothing new to read.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};

use notify::{EventKind, RecursiveMode, Watcher};
use tokio::sync::Notify;

pub(super) struct TranscriptWatch {
    changed: Arc<Notify>,
    /// The transcripts to report, by canonical path; read by the event handler.
    wanted: Arc<Mutex<HashSet<PathBuf>>>,
    watching: Mutex<Watching>,
}

struct Watching {
    watcher: notify::RecommendedWatcher,
    /// Each watched directory (canonical) and whether it stands in for a missing one.
    directories: HashMap<PathBuf, RecursiveMode>,
}

impl TranscriptWatch {
    pub(super) fn new() -> io::Result<Self> {
        let changed = Arc::new(Notify::new());
        let wanted = Arc::new(Mutex::new(HashSet::<PathBuf>::new()));
        let (telling, reported) = (Arc::clone(&changed), Arc::clone(&wanted));
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let relevant = match event {
                // Events may have been dropped: read everything again.
                Err(_) => true,
                Ok(event) if event.need_rescan() => true,
                Ok(event) if matches!(event.kind, EventKind::Access(_)) => false,
                Ok(event) => {
                    let wanted = reported.lock().unwrap_or_else(|p| p.into_inner());
                    event.paths.iter().any(|path| wanted.contains(path))
                }
            };
            if relevant {
                telling.notify_one();
            }
        })
        .map_err(io::Error::other)?;
        Ok(Self {
            changed,
            wanted,
            watching: Mutex::new(Watching {
                watcher,
                directories: HashMap::new(),
            }),
        })
    }

    /// Watches exactly these transcripts from now on, whether they exist yet or not. Call it
    /// before reading them.
    pub(super) fn watch<'a>(&self, transcripts: impl IntoIterator<Item = &'a Path>) {
        let mut wanted = HashSet::new();
        let mut directories = HashMap::new();
        for transcript in transcripts {
            let Some((canonical, directory, mode)) = place(transcript) else {
                continue;
            };
            wanted.insert(canonical);
            // A directory watched itself wins over standing in for a missing one.
            let entry = directories.entry(directory).or_insert(mode);
            if mode == RecursiveMode::NonRecursive {
                *entry = mode;
            }
        }
        // Wanted first: an event in a directory about to be watched is not dropped.
        *self.wanted.lock().unwrap_or_else(|p| p.into_inner()) = wanted;
        let mut watching = self.watching.lock().unwrap_or_else(|p| p.into_inner());
        let stale: Vec<PathBuf> = watching
            .directories
            .iter()
            .filter(|(directory, mode)| directories.get(*directory) != Some(mode))
            .map(|(directory, _)| directory.clone())
            .collect();
        for directory in stale {
            let _ = watching.watcher.unwatch(&directory);
            watching.directories.remove(&directory);
        }
        for (directory, mode) in directories {
            if watching.directories.contains_key(&directory) {
                continue;
            }
            match watching.watcher.watch(&directory, mode) {
                Ok(()) => {
                    watching.directories.insert(directory, mode);
                }
                Err(error) => log::warn!("event=sync.watch outcome=failed reason={error}"),
            }
        }
    }

    /// Waits until a watched transcript changed since the last call.
    pub(super) async fn changed(&self) -> io::Result<()> {
        self.changed.notified().await;
        Ok(())
    }
}

/// Where `transcript` is watched from: its canonical path as events name it, and the directory
/// to watch (its own, or its nearest existing ancestor, recursively, while that is missing).
fn place(transcript: &Path) -> Option<(PathBuf, PathBuf, RecursiveMode)> {
    let directory = transcript.parent()?;
    let name = transcript.file_name()?;
    if let Ok(directory) = directory.canonicalize() {
        return Some((directory.join(name), directory, RecursiveMode::NonRecursive));
    }
    let mut missing = vec![name.to_owned()];
    let mut ancestor = directory;
    loop {
        if let Ok(existing) = ancestor.canonicalize() {
            let canonical = missing
                .iter()
                .rev()
                .fold(existing.clone(), |path, part| path.join(part));
            return Some((canonical, existing, RecursiveMode::Recursive));
        }
        match ancestor.components().next_back() {
            Some(Component::Normal(part)) => missing.push(part.to_owned()),
            _ => return None,
        }
        ancestor = ancestor.parent()?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn directory(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "axo-watch-{name}-{}-{:?}",
            std::process::id(),
            std::time::Instant::now()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    async fn changes_within(watch: &TranscriptWatch, within: Duration) -> bool {
        tokio::time::timeout(within, watch.changed()).await.is_ok()
    }

    /// Takes what is already reported (FSEvents also reports what happened just before a stream
    /// started, and one write as more than one event), until nothing more comes.
    async fn settle(watch: &TranscriptWatch) {
        while changes_within(watch, Duration::from_millis(200)).await {}
    }

    #[tokio::test]
    async fn a_write_to_a_watched_transcript_is_a_change_and_nothing_else_is() {
        let transcript = directory("write").join("t.jsonl");
        std::fs::write(&transcript, "a\n").unwrap();
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        settle(&watch).await;
        std::fs::OpenOptions::new()
            .append(true)
            .open(&transcript)
            .and_then(|mut file| std::io::Write::write_all(&mut file, b"b\n"))
            .unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        settle(&watch).await;
        std::fs::write(transcript.with_file_name("other"), "x").unwrap();
        assert!(!changes_within(&watch, Duration::from_millis(300)).await);
    }

    #[tokio::test]
    async fn creating_a_transcript_that_did_not_exist_is_a_change() {
        let transcript = directory("create").join("t.jsonl");
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        std::fs::write(&transcript, "a\n").unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        // Another file beside it is not a change.
        watch.watch([transcript.as_path()]);
        settle(&watch).await;
        std::fs::write(transcript.with_file_name("other"), "x").unwrap();
        assert!(!changes_within(&watch, Duration::from_millis(300)).await);
    }

    #[tokio::test]
    async fn a_transcript_replaced_at_its_path_is_watched_again() {
        let transcript = directory("replace").join("t.jsonl");
        std::fs::write(&transcript, "a\n").unwrap();
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        settle(&watch).await;
        let replacement = transcript.with_extension("new");
        std::fs::write(&replacement, "a\n").unwrap();
        std::fs::rename(&replacement, &transcript).unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        watch.watch([transcript.as_path()]);
        settle(&watch).await;
        std::fs::write(&transcript, "a\nb\n").unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
    }

    #[tokio::test]
    async fn a_transcript_whose_directory_does_not_exist_yet_is_seen_when_created() {
        let transcript = directory("later").join("host").join("t.jsonl");
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        std::fs::write(transcript.with_file_name("other"), "x").unwrap();
        assert!(!changes_within(&watch, Duration::from_millis(300)).await);
        std::fs::write(&transcript, "a\n").unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        // From the next turn on its own directory is watched.
        watch.watch([transcript.as_path()]);
        settle(&watch).await;
        std::fs::write(&transcript, "a\nb\n").unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
    }

    #[tokio::test]
    async fn a_transcript_no_longer_open_is_no_longer_watched() {
        let transcript = directory("forget").join("t.jsonl");
        std::fs::write(&transcript, "a\n").unwrap();
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        settle(&watch).await;
        watch.watch([]);
        std::fs::write(&transcript, "a\nb\n").unwrap();
        assert!(!changes_within(&watch, Duration::from_millis(300)).await);
    }
}

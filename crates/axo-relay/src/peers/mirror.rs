//! The copies on disk: one file per Session in its Mac's folder under `sessions/`, with a state
//! file saying how far it is valid.

use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::json;

/// Where a copy has got to, within one epoch of the cloud's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CopyState {
    pub epoch: u64,
    pub cursor: u64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ClientRecord {
    pub cursor: u64,
    pub line: String,
}

/// Which copy: the Mac that owns the Session, and the Session.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Place {
    pub host_id: String,
    pub session_id: String,
}

impl Place {
    /// The place of a listed Session, if both parts are safe folder names.
    pub fn of(host_id: &str, session_id: &str) -> Option<Self> {
        [host_id, session_id]
            .iter()
            .all(|part| is_id(part))
            .then(|| Self {
                host_id: host_id.to_owned(),
                session_id: session_id.to_owned(),
            })
    }
}

/// Letters, digits and hyphens: an id, never `..` or a path.
fn is_id(part: &str) -> bool {
    !part.is_empty()
        && part.len() <= 64
        && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// The copies on disk, under `sessions/`.
pub struct Mirror {
    root: PathBuf,
    /// Copies checked against their state since this process started.
    checked: HashSet<Place>,
}

impl Mirror {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            checked: HashSet::new(),
        }
    }

    fn folder(&self, place: &Place) -> PathBuf {
        self.root.join(&place.host_id)
    }

    pub fn file(&self, place: &Place) -> PathBuf {
        self.folder(place)
            .join(format!("{}.jsonl", place.session_id))
    }

    fn state_file(&self, place: &Place) -> PathBuf {
        self.folder(place)
            .join(format!("{}.state.json", place.session_id))
    }

    /// `host.json` says which Mac a folder is, as this Mac's own folder does.
    pub fn describe_host(&self, host_id: &str, label: &str) -> io::Result<()> {
        if !is_id(host_id) {
            return Ok(());
        }
        let folder = self.root.join(host_id);
        fs::create_dir_all(&folder)?;
        let description = json!({ "hostId": host_id, "label": label });
        write_atomically(
            &folder.join("host.json"),
            &serde_json::to_vec_pretty(&description).map_err(io::Error::other)?,
        )
    }

    /// Deletes a copy: an archived Session no pane shows. The cloud holds it, and opening it
    /// fetches it again.
    pub fn forget(&mut self, place: &Place) -> io::Result<bool> {
        self.checked.remove(place);
        let mut removed = false;
        for path in [self.file(place), self.state_file(place)] {
            match fs::remove_file(&path) {
                Ok(()) => removed = true,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        Ok(removed)
    }

    /// Where the copy is, or None if there is no usable copy.
    pub fn state(&mut self, place: &Place) -> io::Result<Option<CopyState>> {
        let Ok(text) = fs::read_to_string(self.state_file(place)) else {
            return Ok(None);
        };
        let Ok(state) = serde_json::from_str::<CopyState>(&text) else {
            return Ok(None);
        };
        if !self.checked.contains(place) {
            // A crash between appending and saving the state leaves lines past the cursor.
            let file = self.file(place);
            match lines_in(&file) {
                Ok(lines) if lines > state.cursor + 1 => truncate_lines(&file, state.cursor + 1)?,
                Ok(lines) if lines == state.cursor + 1 => {}
                _ => return Ok(None),
            }
            self.checked.insert(place.clone());
        }
        Ok(Some(state))
    }

    /// The first records of a copy from nothing.
    pub fn start(
        &mut self,
        place: &Place,
        epoch: u64,
        header: &str,
        records: &[ClientRecord],
    ) -> io::Result<CopyState> {
        fs::create_dir_all(self.folder(place))?;
        let mut out = File::create(self.file(place))?;
        writeln!(out, "{}", one_line(header)?)?;
        out.sync_data()?;
        let state = CopyState { epoch, cursor: 0 };
        self.save(place, state)?;
        self.checked.insert(place.clone());
        self.append(place, epoch, records)
    }

    /// Appends the records that follow the copy. Records it holds already are skipped; a gap or
    /// another epoch is refused, and the Session is opened again from the copy.
    pub fn append(
        &mut self,
        place: &Place,
        epoch: u64,
        records: &[ClientRecord],
    ) -> io::Result<CopyState> {
        let Some(mut state) = self.state(place)? else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "no copy to append to",
            ));
        };
        if state.epoch != epoch {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "records of another epoch",
            ));
        }
        let fresh: Vec<&ClientRecord> = records
            .iter()
            .filter(|record| record.cursor > state.cursor)
            .collect();
        if fresh.is_empty() {
            return Ok(state);
        }
        let mut text = String::new();
        for (index, record) in fresh.iter().enumerate() {
            if record.cursor != state.cursor + 1 + index as u64 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "a gap in the records",
                ));
            }
            text.push_str(one_line(&record.line)?);
            text.push('\n');
        }
        let mut out = OpenOptions::new().append(true).open(self.file(place))?;
        out.write_all(text.as_bytes())?;
        out.sync_data()?;
        state.cursor += fresh.len() as u64;
        self.save(place, state)?;
        Ok(state)
    }

    /// The source Mac rewrote history: keep the header and the first `keep` records.
    pub fn reset(&mut self, place: &Place, epoch: u64, keep: u64) -> io::Result<CopyState> {
        let Some(state) = self.state(place)? else {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no copy to reset"));
        };
        let keep = keep.min(state.cursor);
        truncate_lines(&self.file(place), keep + 1)?;
        let state = CopyState {
            epoch,
            cursor: keep,
        };
        self.save(place, state)?;
        Ok(state)
    }

    fn save(&self, place: &Place, state: CopyState) -> io::Result<()> {
        write_atomically(
            &self.state_file(place),
            &serde_json::to_vec(&state).map_err(io::Error::other)?,
        )
    }
}

/// A Pi line is one JSON value on one line; anything else would corrupt the copy.
fn one_line(line: &str) -> io::Result<&str> {
    if line.contains('\n') || line.contains('\r') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "a record spans lines",
        ));
    }
    Ok(line)
}

fn lines_in(path: &Path) -> io::Result<u64> {
    let mut count = 0;
    for line in BufReader::new(File::open(path)?).split(b'\n') {
        line?;
        count += 1;
    }
    Ok(count)
}

/// Keeps the first `lines` lines of the file.
fn truncate_lines(path: &Path, lines: u64) -> io::Result<()> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut length = 0_u64;
    let mut buffer = Vec::new();
    for _ in 0..lines {
        buffer.clear();
        let read = reader.read_until(b'\n', &mut buffer)?;
        if read == 0 {
            break;
        }
        length += read as u64;
    }
    OpenOptions::new().write(true).open(path)?.set_len(length)
}

pub(super) fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut file = File::create(&temporary)?;
    file.write_all(bytes)?;
    file.sync_data()?;
    fs::rename(temporary, path)
}

/// Records of a copy, read while the peers worker may be writing it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CopyRead {
    pub state: CopyState,
    /// Records after the cursor asked for, as `(cursor, line)`, oldest first.
    pub records: Vec<(u64, String)>,
}

/// Reads the records of a copy after `after`, at most the last `limit` of them; None if there
/// is no copy. Only records the state file counts are read, so lines being appended are not.
/// `after` beyond the copy (another epoch, or a cut) reads nothing; the caller compares epochs.
pub fn read_copy(
    sessions_directory: &Path,
    place: &Place,
    after: u64,
    limit: usize,
) -> io::Result<Option<CopyRead>> {
    let mirror = Mirror::new(sessions_directory.to_path_buf());
    let Ok(text) = fs::read_to_string(mirror.state_file(place)) else {
        return Ok(None);
    };
    let Ok(state) = serde_json::from_str::<CopyState>(&text) else {
        return Ok(None);
    };
    let file = match File::open(mirror.file(place)) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let first = after.max(state.cursor.saturating_sub(limit as u64)) + 1;
    let mut records = Vec::new();
    // Line 0 is Pi's header; line n is record n.
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let cursor = index as u64;
        if cursor > state.cursor {
            break;
        }
        let line = line?;
        if cursor >= first {
            records.push((cursor, line));
        }
    }
    Ok(Some(CopyRead { state, records }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peers::test_support::{
        HEADER, HOST, SESSION, Scratch, copy, expected, place, record, records,
    };

    #[test]
    fn a_copy_is_in_its_macs_folder_under_sessions() {
        let scratch = Scratch::new();
        let mirror = Mirror::new(scratch.0.clone());
        assert_eq!(
            mirror.file(&place()),
            scratch.0.join(HOST).join(format!("{SESSION}.jsonl"))
        );
    }

    #[test]
    fn a_place_the_cloud_names_must_be_ids() {
        assert!(Place::of("..", SESSION).is_none());
        assert!(Place::of("../../server", SESSION).is_none());
        assert!(Place::of(HOST, "a/b").is_none());
        assert!(Place::of("", SESSION).is_none());
    }

    #[test]
    fn a_copy_is_the_header_and_the_records_in_order() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        assert_eq!(mirror.state(&place()).unwrap(), None);
        mirror.start(&place(), 1, HEADER, &records(1..=3)).unwrap();
        // A batch that repeats what the copy holds adds only what follows.
        let state = mirror.append(&place(), 1, &records(2..=5)).unwrap();
        assert_eq!(
            state,
            CopyState {
                epoch: 1,
                cursor: 5
            }
        );
        assert_eq!(copy(&mirror), expected(1..=5));
    }

    #[test]
    fn a_gap_or_another_epoch_is_refused_and_changes_nothing() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=2)).unwrap();
        assert_eq!(
            mirror
                .append(&place(), 1, &records(4..=5))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            mirror
                .append(&place(), 2, &records(3..=3))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(copy(&mirror), expected(1..=2));
    }

    #[test]
    fn a_reset_cuts_the_copy_back_and_it_goes_on_in_the_new_epoch() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=5)).unwrap();
        assert_eq!(
            mirror.reset(&place(), 2, 3).unwrap(),
            CopyState {
                epoch: 2,
                cursor: 3
            }
        );
        mirror.append(&place(), 2, &records(4..=4)).unwrap();
        assert_eq!(copy(&mirror), expected(1..=4));
    }

    #[test]
    fn lines_written_but_not_saved_before_a_crash_are_dropped() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=2)).unwrap();
        let mut out = OpenOptions::new()
            .append(true)
            .open(mirror.file(&place()))
            .unwrap();
        writeln!(out, "{}", record(3).line).unwrap();
        // A new process checks the copy against its state once.
        let mut restarted = Mirror::new(scratch.0.clone());
        assert_eq!(
            restarted.state(&place()).unwrap(),
            Some(CopyState {
                epoch: 1,
                cursor: 2
            })
        );
        assert_eq!(copy(&restarted), expected(1..=2));
        // A copy shorter than its state is no copy: it is made again from nothing.
        fs::write(restarted.file(&place()), format!("{HEADER}\n")).unwrap();
        assert_eq!(
            Mirror::new(scratch.0.clone()).state(&place()).unwrap(),
            None
        );
    }

    #[test]
    fn a_pane_reads_only_the_records_the_state_counts_after_its_cursor() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 3, HEADER, &records(1..=4)).unwrap();
        // A line appended but not yet counted is not read.
        let mut out = OpenOptions::new()
            .append(true)
            .open(mirror.file(&place()))
            .unwrap();
        writeln!(out, "{}", record(5).line).unwrap();
        let read = read_copy(&scratch.0, &place(), 2, usize::MAX)
            .unwrap()
            .unwrap();
        assert_eq!(
            read.state,
            CopyState {
                epoch: 3,
                cursor: 4
            }
        );
        assert_eq!(
            read.records
                .iter()
                .map(|(cursor, _)| *cursor)
                .collect::<Vec<_>>(),
            vec![3, 4]
        );
        assert_eq!(read.records[0].1, record(3).line);
        let window = read_copy(&scratch.0, &place(), 0, 2).unwrap().unwrap();
        assert_eq!(
            window
                .records
                .iter()
                .map(|(cursor, _)| *cursor)
                .collect::<Vec<_>>(),
            vec![3, 4],
            "starting over reads the newest `limit`"
        );
        let elsewhere = Place::of(HOST, "8f8f8f8f-0000-4000-8000-000000000002").unwrap();
        assert!(read_copy(&scratch.0, &elsewhere, 0, 10).unwrap().is_none());
    }

    #[test]
    fn an_archived_copy_can_be_forgotten_and_copied_again_from_nothing() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=2)).unwrap();
        assert!(mirror.forget(&place()).unwrap());
        assert!(!mirror.file(&place()).exists());
        assert_eq!(
            mirror.state(&place()).unwrap(),
            None,
            "the next open starts from nothing"
        );
        assert!(
            !mirror.forget(&place()).unwrap(),
            "forgetting twice is harmless"
        );
        mirror.start(&place(), 1, HEADER, &records(1..=2)).unwrap();
        assert_eq!(
            mirror.state(&place()).unwrap(),
            Some(CopyState {
                epoch: 1,
                cursor: 2
            })
        );
    }
}

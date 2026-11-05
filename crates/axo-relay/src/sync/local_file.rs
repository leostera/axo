//! A Session's Pi file as the uploader reads it: hashed record by record as far as its last
//! complete line, and hashed again from the start if it is rewritten.

use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::time::Instant;

use crate::pi3::{self, Transcript};

/// A Session's Pi file, hashed as far as its last complete line.
pub(super) struct LocalFile {
    pub(super) path: Option<PathBuf>,
    pub(super) transcript: Option<Transcript>,
    /// Where each record's line starts in the file and how long it is (index = position - 1).
    pub(super) lines: Vec<(u64, usize)>,
    /// Bytes of the file hashed: whole lines only.
    hashed: u64,
    /// The last record's content digest, to notice a file rewritten in place.
    last_digest: Option<String>,
    /// The first line that is not a record; nothing from there is uploaded until the file changes.
    pub(super) invalid: bool,
    pub(super) checked_at: Option<Instant>,
}

impl LocalFile {
    pub(super) fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            transcript: None,
            lines: Vec::new(),
            hashed: 0,
            last_digest: None,
            invalid: false,
            checked_at: None,
        }
    }

    pub(super) fn count(&self) -> u64 {
        self.transcript.as_ref().map_or(0, Transcript::count)
    }

    /// Hashes lines appended since the last check. A file that shrank, or whose last hashed line
    /// changed, is hashed again from the start. Returns whether anything changed.
    pub(super) fn refresh(&mut self) -> io::Result<bool> {
        self.checked_at = Some(Instant::now());
        let Some(path) = self.path.clone() else {
            return Ok(false);
        };
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error),
        };
        let length = file.metadata()?.len();
        if length < self.hashed || !self.last_line_unchanged(&mut file)? {
            *self = Self::new(Some(path.clone()));
            self.checked_at = Some(Instant::now());
        }
        if length == self.hashed {
            return Ok(false);
        }
        file.seek(SeekFrom::Start(self.hashed))?;
        let mut appended = Vec::new();
        file.take(length - self.hashed).read_to_end(&mut appended)?;
        let mut changed = false;
        let mut start = 0;
        while let Some(end) = appended[start..].iter().position(|&b| b == b'\n') {
            let line = &appended[start..start + end];
            let offset = self.hashed + start as u64;
            start += end + 1;
            changed = true;
            if self.invalid {
                continue;
            }
            let Some(text) = std::str::from_utf8(line)
                .ok()
                .filter(|_| line.len() <= pi3::MAX_LINE_BYTES)
            else {
                self.mark_invalid(&path);
                continue;
            };
            match &mut self.transcript {
                None => self.transcript = Some(Transcript::start(text)),
                Some(transcript) => {
                    if transcript.push(text).is_none() {
                        self.mark_invalid(&path);
                        continue;
                    }
                    self.lines.push((offset, line.len()));
                    self.last_digest = Some(pi3::digest("content", text));
                }
            }
        }
        // A last line without its newline is not complete yet; it waits.
        self.hashed += start as u64;
        Ok(changed)
    }

    /// Every byte of the file is a record already hashed: nothing partial, nothing refused.
    /// Returns its length then.
    pub(super) fn whole_length(&self) -> io::Result<Option<u64>> {
        let Some(path) = &self.path else {
            return Ok(None);
        };
        let length = match fs::metadata(path) {
            Ok(metadata) => metadata.len(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        Ok((!self.invalid && self.transcript.is_some() && length == self.hashed).then_some(length))
    }

    fn mark_invalid(&mut self, path: &std::path::Path) {
        self.invalid = true;
        log::warn!(
            "event=sync.invalid_line position={} file={}",
            self.count() + 1,
            path.file_name().unwrap_or_default().to_string_lossy()
        );
    }

    fn last_line_unchanged(&self, file: &mut File) -> io::Result<bool> {
        let (Some(&(offset, length)), Some(digest)) = (self.lines.last(), &self.last_digest) else {
            return Ok(true);
        };
        file.seek(SeekFrom::Start(offset))?;
        let mut line = vec![0; length];
        if file.read_exact(&mut line).is_err() {
            return Ok(false);
        }
        Ok(std::str::from_utf8(&line).is_ok_and(|text| &pi3::digest("content", text) == digest))
    }

    /// The raw lines of positions `from..=to`, read from the file.
    pub(super) fn read(&self, from: u64, to: u64) -> io::Result<Vec<String>> {
        let path = self.path.as_ref().ok_or(io::ErrorKind::NotFound)?;
        let mut file = File::open(path)?;
        (from..=to)
            .map(|position| {
                let (offset, length) = self.lines[(position - 1) as usize];
                file.seek(SeekFrom::Start(offset))?;
                let mut line = vec![0; length];
                file.read_exact(&mut line)?;
                String::from_utf8(line).map_err(|_| io::ErrorKind::InvalidData.into())
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    use crate::sync::test_support::{HEADER, temp_file};

    #[test]
    fn a_file_is_hashed_line_by_line_and_a_partial_last_line_waits() {
        let path = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\":\"b\""
        ));
        let mut file = LocalFile::new(Some(path.clone()));
        assert!(file.refresh().unwrap());
        assert_eq!(file.count(), 1);
        let mut handle = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        handle.write_all(b",\"parentId\":\"a\"}\n").unwrap();
        assert!(file.refresh().unwrap());
        assert_eq!(file.count(), 2);
        assert_eq!(
            file.read(1, 2).unwrap(),
            vec![
                r#"{"id":"a","parentId":null}"#,
                r#"{"id":"b","parentId":"a"}"#
            ]
        );
        let mut expected = Transcript::start(HEADER);
        expected.push(r#"{"id":"a","parentId":null}"#);
        expected.push(r#"{"id":"b","parentId":"a"}"#);
        assert_eq!(file.transcript.as_ref().unwrap().chain(), expected.chain());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_rewritten_file_is_hashed_again_from_the_start() {
        let path = temp_file(&format!("{HEADER}\n{{\"id\":\"a\"}}\n{{\"id\":\"b\"}}\n"));
        let mut file = LocalFile::new(Some(path.clone()));
        file.refresh().unwrap();
        assert_eq!(file.count(), 2);
        std::fs::write(
            &path,
            format!("{HEADER}\n{{\"id\":\"a\"}}\n{{\"id\":\"c\"}}\n"),
        )
        .unwrap();
        file.refresh().unwrap();
        let mut expected = Transcript::start(HEADER);
        expected.push(r#"{"id":"a"}"#);
        expected.push(r#"{"id":"c"}"#);
        assert_eq!(file.transcript.as_ref().unwrap().chain(), expected.chain());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_line_that_is_not_a_record_stops_the_upload_there() {
        let path = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\"}}\nnot json\n{{\"id\":\"b\"}}\n"
        ));
        let mut file = LocalFile::new(Some(path.clone()));
        file.refresh().unwrap();
        assert_eq!(file.count(), 1);
        assert!(file.invalid);
        std::fs::remove_file(path).unwrap();
    }
}

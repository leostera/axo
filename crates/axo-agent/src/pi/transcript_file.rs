//! A Session's Pi file as it is read for upload: hashed record by record as far as its last
//! complete line, and hashed again from the start if it is rewritten.

use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use super::pi3::{self, Transcript};

/// A Session's Pi file, hashed as far as its last complete line.
pub struct TranscriptFile {
    path: Option<PathBuf>,
    transcript: Option<Transcript>,
    /// Each record's line in the file (index = position - 1).
    lines: Vec<LineSpan>,
    /// Bytes of the file hashed: whole lines only.
    hashed: u64,
    /// The last record's content digest, to notice a file rewritten in place.
    last_digest: Option<String>,
    /// The first line that is not a record; nothing from there is uploaded until the file changes.
    invalid: bool,
}

impl TranscriptFile {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            transcript: None,
            lines: Vec::new(),
            hashed: 0,
            last_digest: None,
            invalid: false,
        }
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// The records hashed so far, once the header has been read.
    pub fn transcript(&self) -> Option<&Transcript> {
        self.transcript.as_ref()
    }

    pub fn count(&self) -> u64 {
        self.transcript.as_ref().map_or(0, Transcript::count)
    }

    /// The length in bytes of the line of record `position` (from 1), without its newline.
    pub fn line_length(&self, position: u64) -> Option<usize> {
        let index = usize::try_from(position.checked_sub(1)?).ok()?;
        self.lines.get(index).map(|span| span.length)
    }

    /// Treats the next record as one that cannot be uploaded, as if it were not a record: nothing
    /// from there is read until the file changes.
    pub fn mark_invalid(&mut self) {
        self.invalid = true;
    }

    pub fn is_invalid(&self) -> bool {
        self.invalid
    }

    /// Hashes lines appended since the last check. A file that shrank, or whose last hashed line
    /// changed, is hashed again from the start. Returns whether anything changed.
    pub fn refresh(&mut self) -> io::Result<bool> {
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
                self.log_invalid_line(&path);
                continue;
            };
            match &mut self.transcript {
                None => self.transcript = Some(Transcript::start(text)),
                Some(transcript) => {
                    if transcript.push(text).is_none() {
                        self.log_invalid_line(&path);
                        continue;
                    }
                    self.lines.push(LineSpan {
                        offset,
                        length: line.len(),
                    });
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
    pub fn whole_length(&self) -> io::Result<Option<u64>> {
        let Some(path) = &self.path else {
            return Ok(None);
        };
        let length = match fs::metadata(path) {
            Ok(metadata) => metadata.len(),
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        Ok(self.is_whole(length).then_some(length))
    }

    /// Whether a file of `length` bytes is every record already hashed, nothing partial and
    /// nothing refused.
    pub fn is_whole(&self, length: u64) -> bool {
        !self.invalid && self.transcript.is_some() && length == self.hashed
    }

    fn log_invalid_line(&mut self, path: &Path) {
        self.invalid = true;
        log::warn!(
            "event=sync.invalid_line position={} file={}",
            self.count() + 1,
            path.file_name().unwrap_or_default().to_string_lossy()
        );
    }

    fn last_line_unchanged(&self, file: &mut File) -> io::Result<bool> {
        let (Some(span), Some(digest)) = (self.lines.last(), &self.last_digest) else {
            return Ok(true);
        };
        file.seek(SeekFrom::Start(span.offset))?;
        let mut line = vec![0; span.length];
        if file.read_exact(&mut line).is_err() {
            return Ok(false);
        }
        Ok(std::str::from_utf8(&line).is_ok_and(|text| &pi3::digest("content", text) == digest))
    }

    /// The raw lines of positions `from..=to`, read from the file.
    pub fn read(&self, from: u64, to: u64) -> io::Result<Vec<String>> {
        self.line_range(from, to)?.read()
    }

    /// Where the lines of positions `from..=to` are, to read them elsewhere: on another thread,
    /// while this file keeps hashing.
    pub fn line_range(&self, from: u64, to: u64) -> io::Result<LineRange> {
        let start = from
            .checked_sub(1)
            .and_then(|index| usize::try_from(index).ok())
            .ok_or(io::ErrorKind::InvalidInput)?;
        let end = usize::try_from(to).map_err(|_| io::ErrorKind::InvalidInput)?;
        if from > to {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let path = self.path.clone().ok_or(io::ErrorKind::NotFound)?;
        let spans = self
            .lines
            .get(start..end)
            .ok_or(io::ErrorKind::InvalidInput)?
            .to_vec();
        Ok(LineRange { path, spans })
    }
}

/// Where one record's line is in its file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineSpan {
    pub offset: u64,
    pub length: usize,
}

/// Some records' lines in a transcript file, in order.
#[derive(Clone, Debug)]
pub struct LineRange {
    path: PathBuf,
    spans: Vec<LineSpan>,
}

impl LineRange {
    /// Reads the lines. Blocks: run it off the runtime.
    pub fn read(self) -> io::Result<Vec<String>> {
        let mut file = File::open(&self.path)?;
        self.spans
            .iter()
            .map(|span| {
                file.seek(SeekFrom::Start(span.offset))?;
                let mut line = vec![0; span.length];
                file.read_exact(&mut line)?;
                String::from_utf8(line).map_err(|_| io::ErrorKind::InvalidData.into())
            })
            .collect()
    }
}

/// How many records a Pi transcript has and the chain at the last, if every line of it is a
/// whole record (RFD0027: a restored transcript must be the one that was deleted).
pub fn transcript_chain(path: &Path) -> io::Result<Option<(u64, String)>> {
    let mut file = TranscriptFile::new(Some(path.to_owned()));
    file.refresh()?;
    if file.whole_length()?.is_none() {
        return Ok(None);
    }
    let count = file.count();
    Ok(file
        .transcript()
        .and_then(|transcript| transcript.chain_at(count))
        .map(|chain| (count, chain.to_owned())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const HEADER: &str = r#"{"type":"session","version":3,"id":"s"}"#;

    fn temp_file(contents: &str) -> PathBuf {
        let path = crate::test_directory().join("transcript.jsonl");
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn line_ranges_reject_zero_reversed_and_unhashed_positions() {
        let file = TranscriptFile::new(Some(PathBuf::from("unused")));
        for (from, to) in [(0, 0), (0, 1), (2, 1), (1, 1), (1, u64::MAX)] {
            assert_eq!(
                file.line_range(from, to).unwrap_err().kind(),
                io::ErrorKind::InvalidInput
            );
        }
    }

    #[test]
    fn a_transcript_has_a_chain_only_when_every_line_is_a_whole_record() {
        let whole = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\":\"b\",\"parentId\":\"a\"}}\n"
        ));
        let mut expected = Transcript::start(HEADER);
        expected.push(r#"{"id":"a","parentId":null}"#);
        expected.push(r#"{"id":"b","parentId":"a"}"#);
        assert_eq!(
            transcript_chain(&whole).unwrap(),
            Some((2, expected.chain().to_owned()))
        );
        let partial = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\""
        ));
        assert_eq!(
            transcript_chain(&partial).unwrap(),
            None,
            "a partial last line"
        );
        let refused = temp_file(&format!("{HEADER}\nnot a record\n"));
        assert_eq!(
            transcript_chain(&refused).unwrap(),
            None,
            "a line that is not a record"
        );
    }

    #[test]
    fn a_file_is_hashed_line_by_line_and_a_partial_last_line_waits() {
        let path = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\":\"b\""
        ));
        let mut file = TranscriptFile::new(Some(path.clone()));
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
        assert_eq!(file.transcript().unwrap().chain(), expected.chain());
    }

    #[test]
    fn a_rewritten_file_is_hashed_again_from_the_start() {
        let path = temp_file(&format!("{HEADER}\n{{\"id\":\"a\"}}\n{{\"id\":\"b\"}}\n"));
        let mut file = TranscriptFile::new(Some(path.clone()));
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
        assert_eq!(file.transcript().unwrap().chain(), expected.chain());
    }

    #[test]
    fn a_line_that_is_not_a_record_stops_the_upload_there() {
        let path = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\"}}\nnot json\n{{\"id\":\"b\"}}\n"
        ));
        let mut file = TranscriptFile::new(Some(path.clone()));
        file.refresh().unwrap();
        assert_eq!(file.count(), 1);
        assert!(file.is_invalid());
    }
}

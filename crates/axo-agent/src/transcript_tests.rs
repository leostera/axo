use super::*;
use serde_json::Value;

const CODEX_ROLLOUT: &str = include_str!("../testdata/atxf/rollout-hand-built.jsonl");
const CLAUDE_SESSION: &str = include_str!("../testdata/atxf/harbor-hello.jsonl");
const OPENCODE_EXPORT: &str = include_str!("../testdata/atxf/export-2.0.20.json");

fn header() -> PiHeader {
    PiHeader {
        session_id: "5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f".into(),
        timestamp: "2026-11-18T12:00:00.000Z".into(),
        cwd: "/work".into(),
    }
}

fn convert(kind: AgentKind, native: &str) -> Result<String, TranscriptError> {
    pi_lines(kind, native, &header())
}

fn lines(text: &str) -> Vec<&str> {
    text.lines().filter(|line| !line.is_empty()).collect()
}

/// The Pi lines as the uploader reads them: a `session` header, then JSON objects that the
/// `pi/3` hashing takes.
fn assert_pi_transcript(text: &str) -> Vec<Value> {
    let lines = lines(text);
    let header: Value = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(
        header,
        serde_json::json!({ "type": "session", "version": 3, "id": "5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f", "timestamp": "2026-11-18T12:00:00.000Z", "cwd": "/work" })
    );
    #[cfg(unix)]
    let mut hashed = crate::pi::pi3::Transcript::start(lines[0]);
    lines[1..]
        .iter()
        .map(|line| {
            #[cfg(unix)]
            assert!(hashed.push(line).is_some(), "not a pi/3 line: {line}");
            serde_json::from_str(line).unwrap()
        })
        .collect()
}

fn texts(entries: &[Value], role: &str) -> Vec<String> {
    entries
        .iter()
        .filter(|entry| entry["type"] == "message" && entry["message"]["role"] == role)
        .map(|entry| entry["message"]["content"].to_string())
        .collect()
}

#[test]
fn a_codex_rollout_becomes_a_pi_transcript_with_its_conversation() {
    let entries = assert_pi_transcript(&convert(AgentKind::Codex, CODEX_ROLLOUT).unwrap());
    let user = texts(&entries, "user");
    assert!(
        user.iter().any(|text| text.contains("List the files")),
        "{user:?}"
    );
    assert!(!texts(&entries, "assistant").is_empty());
}

#[test]
fn a_claude_code_session_becomes_a_pi_transcript() {
    let entries = assert_pi_transcript(&convert(AgentKind::ClaudeCode, CLAUDE_SESSION).unwrap());
    assert!(!texts(&entries, "user").is_empty());
    assert!(!texts(&entries, "assistant").is_empty());
}

#[test]
fn an_opencode_export_becomes_a_pi_transcript() {
    let entries = assert_pi_transcript(&convert(AgentKind::OpenCode, OPENCODE_EXPORT).unwrap());
    assert!(!texts(&entries, "user").is_empty());
    assert!(!texts(&entries, "assistant").is_empty());
}

#[test]
fn pi_is_never_converted_and_garbage_is_an_error() {
    assert!(matches!(
        convert(AgentKind::Pi, "{}"),
        Err(TranscriptError::NotConverted(AgentKind::Pi))
    ));
    // A line that is not JSON is kept by ATXF as an opaque record, never dropped; a file that
    // is not an export at all fails.
    if let Ok(text) = convert(AgentKind::Codex, "not json\n") {
        assert_pi_transcript(&text);
    }
}

#[test]
fn conversion_is_deterministic() {
    for (kind, native) in [
        (AgentKind::Codex, CODEX_ROLLOUT),
        (AgentKind::ClaudeCode, CLAUDE_SESSION),
        (AgentKind::OpenCode, OPENCODE_EXPORT),
    ] {
        assert_eq!(
            convert(kind, native).unwrap(),
            convert(kind, native).unwrap()
        );
    }
}

/// Agents append to their conversation files. Converting a file that grew by whole lines keeps
/// the header and every Pi line the shorter file gave but the last, so the uploader sends only
/// what is new and the cloud's copy is cut back at most one record (the last, which may still
/// be changing).
#[test]
fn a_conversation_that_grows_keeps_what_was_already_synced() {
    for (kind, native) in [
        (AgentKind::Codex, CODEX_ROLLOUT),
        (AgentKind::ClaudeCode, CLAUDE_SESSION),
    ] {
        let native = lines(native);
        let mut previous: Option<Vec<String>> = None;
        for end in 1..=native.len() {
            let prefix = native[..end].join("\n") + "\n";
            let Ok(converted) = convert(kind, &prefix) else {
                continue;
            };
            let converted: Vec<String> = lines(&converted).into_iter().map(str::to_owned).collect();
            if let Some(previous) = &previous {
                let kept = previous.len().saturating_sub(1);
                assert!(
                    converted.len() >= kept && converted[..kept] == previous[..kept],
                    "{kind}: after line {end}, the Pi lines before it changed"
                );
            }
            previous = Some(converted);
        }
        assert!(previous.is_some(), "{kind}: no prefix converted");
    }
}

/// Whatever an agent's file holds, converting it fails or gives a Pi transcript; it never
/// panics. Mutations of the fixtures: dropped, duplicated, truncated and corrupted lines.
#[test]
fn mutated_conversations_never_panic_and_convert_to_pi_transcripts_or_fail() {
    let mut seed = 0x2545_f491_4f6c_dd1d_u64;
    let mut next = move |bound: usize| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        (seed % bound.max(1) as u64) as usize
    };
    for (kind, native) in [
        (AgentKind::Codex, CODEX_ROLLOUT),
        (AgentKind::ClaudeCode, CLAUDE_SESSION),
    ] {
        let original = lines(native);
        for _ in 0..300 {
            let mut mutated: Vec<String> = original.iter().map(|line| (*line).to_owned()).collect();
            for _ in 0..1 + next(3) {
                let at = next(mutated.len());
                match next(4) {
                    0 if mutated.len() > 1 => {
                        mutated.remove(at);
                    }
                    1 => {
                        let line = mutated[at].clone();
                        mutated.insert(at, line);
                    }
                    2 => {
                        let line = &mut mutated[at];
                        let cut = next(line.len());
                        line.truncate(line.floor_char_boundary(cut));
                    }
                    _ => {
                        let line = &mut mutated[at];
                        if !line.is_empty() {
                            let byte = next(line.len());
                            let byte = line.floor_char_boundary(byte);
                            line.replace_range(byte..byte, "\"}{");
                        }
                    }
                }
            }
            let text = mutated.join("\n") + "\n";
            if let Ok(converted) = convert(kind, &text)
                && !converted.trim().is_empty()
            {
                assert_pi_transcript(&converted);
            }
        }
    }
}

#[test]
fn the_transcript_is_replaced_whole_and_only_when_it_changed() {
    let directory = crate::test_directory();
    let transcript = directory.join("s.jsonl");
    assert!(write_if_changed(&transcript, "a\n").unwrap());
    assert!(!write_if_changed(&transcript, "a\n").unwrap());
    assert!(write_if_changed(&transcript, "a\nb\n").unwrap());
    assert_eq!(std::fs::read_to_string(&transcript).unwrap(), "a\nb\n");
    assert!(!directory.join("s.jsonl.writing").exists());
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn timestamps_are_written_as_pi_writes_them() {
    assert_eq!(rfc3339_utc(0), "1970-01-01T00:00:00.000Z");
    assert_eq!(rfc3339_utc(951_782_400), "2000-02-29T00:00:00.000Z");
    assert_eq!(rfc3339_utc(1_763_467_200), "2025-11-18T12:00:00.000Z");
    assert_eq!(rfc3339_utc(-1), "1969-12-31T23:59:59.000Z");
}

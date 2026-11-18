//! The app and terminal use the same non-overwriting installer. System installation may ask
//! macOS for authorization, but never runs this user-writable executable as root.
use super::{Failure, home, output};
use clap::ArgMatches;
use serde_json::json;
use std::io;
use std::path::{Path, PathBuf};

pub(crate) const SYSTEM_DIRECTORY: &str = "/usr/local/bin";

fn same_link(link: &Path, source: &Path) -> bool {
    std::fs::read_link(link).ok().as_deref() == Some(source)
}
fn create_link(source: &Path, directory: &Path) -> io::Result<()> {
    let link = directory.join("axo");
    if same_link(&link, source) {
        return Ok(());
    }
    // Refuse visible conflicts before trying a write (and before any authorization prompt).
    match std::fs::symlink_metadata(&link) {
        Ok(_) => return Err(io::ErrorKind::AlreadyExists.into()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    std::fs::create_dir_all(directory)?;
    match std::os::unix::fs::symlink(source, &link) {
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists && same_link(&link, source) => {
            Ok(())
        }
        other => other,
    }
}
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
fn applescript_quote(value: &str) -> String {
    format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
    )
}
// Use the actual symlink syscall through the OS Foundation bridge. Unlike BSD ln, this
// cannot follow a racing destination directory and create an unexpected nested entry.
fn filesystem_script(source: &Path, directory: &Path) -> Result<String, Failure> {
    let source = source
        .to_str()
        .ok_or_else(|| Failure::input("system installation requires a UTF-8 app location"))?;
    let directory = directory
        .to_str()
        .ok_or_else(|| Failure::input("bin directory must be UTF-8"))?;
    if !Path::new(source).is_absolute() {
        return Err(Failure::input("CLI source must be absolute"));
    }
    let source = json!(source).to_string();
    let directory = json!(directory).to_string();
    Ok(format!(
        r#"ObjC.import('Foundation');
const source = {source};
const directory = {directory};
const destination = directory + '/axo';
const files = $.NSFileManager.defaultManager;
const previous = ObjC.unwrap(files.destinationOfSymbolicLinkAtPathError(destination, Ref()));
if (previous !== source) {{
  const error = Ref();
  const attributes = $.NSDictionary.dictionaryWithObjectForKey($(493), $.NSFilePosixPermissions);
  if (!files.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(directory, true, attributes, error))
    throw Error('AXO_CLI_DIRECTORY_FAILED');
  if (!files.createSymbolicLinkAtPathWithDestinationPathError(destination, source, error))
    throw Error('AXO_CLI_LINK_FAILED');
}}
"#
    ))
}
fn authorization_script(source: &Path) -> Result<String, Failure> {
    // Only this fixed destination is eligible for administrator authorization.
    let javascript = filesystem_script(source, Path::new(SYSTEM_DIRECTORY))?;
    let command = format!(
        "/usr/bin/osascript -l JavaScript -e {}",
        shell_quote(&javascript)
    );
    Ok(format!(
        "do shell script {} with administrator privileges",
        applescript_quote(&command)
    ))
}
/// Runs one AppleScript and answers how it went: `osascript` itself, or a stand-in in tests,
/// which never ask for administrator authorization (and whose `osascript` a Mac's security
/// software may kill).
type Osascript<'a> = &'a dyn Fn(&str) -> io::Result<std::process::Output>;

fn osascript(script: &str) -> io::Result<std::process::Output> {
    std::process::Command::new("/usr/bin/osascript")
        .args(["-e", script])
        .output()
}

fn authorize(source: &Path, osascript: Osascript) -> Result<(), Failure> {
    let script = authorization_script(source)?;
    let result = osascript(&script)?;
    if !result.status.success() && !same_link(&Path::new(SYSTEM_DIRECTORY).join("axo"), source) {
        let error = String::from_utf8_lossy(&result.stderr);
        let message = if error.contains("AXO_CLI_LINK_FAILED") {
            "Could not create /usr/local/bin/axo; check for another file or link there. Nothing was replaced"
        } else if error.contains("(-128)") {
            "Command installation was cancelled"
        } else {
            "Could not install /usr/local/bin/axo; check permissions or choose a user bin directory with --dir"
        };
        return Err(Failure::input(message));
    }
    Ok(())
}
pub(crate) fn install(matches: &ArgMatches) -> Result<(), Failure> {
    let system = matches.get_flag("system");
    if system && !cfg!(target_os = "macos") {
        return Err(Failure::input(
            "--system authorization is available on macOS only",
        ));
    }
    let directory = if system {
        PathBuf::from(SYSTEM_DIRECTORY)
    } else {
        match matches.get_one::<String>("dir") {
            Some(dir) => PathBuf::from(dir),
            None => home()?.join(".local/bin"),
        }
    };
    if !directory.is_absolute() {
        return Err(Failure::input("--dir must be absolute"));
    }
    let executable = std::env::current_exe()?.canonicalize()?;
    if system && executable.to_string_lossy().contains("/AppTranslocation/") {
        return Err(Failure::input(
            "Move Axo to Applications, open it there, then install the command again",
        ));
    }
    let link = directory.join("axo");
    match create_link(&executable, &directory) {
        Ok(()) => {}
        Err(error) if system && error.kind() == io::ErrorKind::PermissionDenied => {
            authorize(&executable, &osascript)?
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            return Err(Failure::input(
                "axo already exists in that directory; it was not replaced",
            ));
        }
        Err(error) => return Err(error.into()),
    }
    if !same_link(&link, &executable) {
        return Err(Failure::input(
            "Installation did not create the expected link; no existing command was replaced",
        ));
    }
    output(
        &json!({"installed":true,"path":link,"target":executable,"note":"Ensure this bin directory is in PATH; shell profiles were not changed"}),
        true,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authorization_and_custom_directory_are_mutually_exclusive_before_effects() {
        assert!(
            super::super::command()
                .try_get_matches_from([
                    "axo",
                    "cli",
                    "install",
                    "--system",
                    "--dir",
                    "/tmp/not-used"
                ])
                .is_err()
        );
    }
    #[test]
    fn privileged_script_only_uses_os_filesystem_api_at_the_fixed_destination() {
        let script =
            authorization_script(Path::new("/Applications/Axo.app/Contents/Helpers/axo")).unwrap();
        assert!(script.starts_with("do shell script \""));
        assert!(script.ends_with("with administrator privileges"));
        assert!(script.contains("/usr/bin/osascript -l JavaScript"));
        assert!(script.contains("/usr/local/bin"));
        assert!(script.contains("createSymbolicLinkAtPathWithDestinationPathError"));
        assert!(!script.contains("/bin/rm"));
        assert!(!script.contains("sudo"));
        assert!(authorization_script(Path::new("relative")).is_err());
    }
    /// What `osascript -e` would see in its string literal: `applescript_quote` undone.
    fn applescript_literal(script: &str) -> String {
        let quoted = script
            .strip_prefix("do shell script \"")
            .and_then(|rest| rest.strip_suffix("\" with administrator privileges"))
            .expect("one do shell script, with administrator privileges");
        let mut literal = String::new();
        let mut characters = quoted.chars();
        while let Some(character) = characters.next() {
            if character != '\\' {
                assert_ne!(character, '"', "an unescaped quote ends the literal early");
                literal.push(character);
                continue;
            }
            literal.push(match characters.next().expect("a whole escape") {
                'n' => '\n',
                'r' => '\r',
                escaped => escaped,
            });
        }
        literal
    }

    fn temporary_root(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "axo-cli-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn finished(code: i32, stderr: &str) -> io::Result<std::process::Output> {
        Ok(std::process::Output {
            status: std::os::unix::process::ExitStatusExt::from_raw(code << 8),
            stdout: Vec::new(),
            stderr: stderr.as_bytes().to_vec(),
        })
    }

    /// The script authorization runs, peeled layer by layer without running osascript: the
    /// AppleScript literal, then the shell command (by `/bin/sh`, with the program's name
    /// printed instead of run), then the JavaScript's literals. A hostile app location stays
    /// one literal at every layer and runs nothing.
    #[test]
    fn os_filesystem_script_keeps_the_app_location_literal_at_every_layer() {
        let root = temporary_root("script");
        std::fs::create_dir_all(&root).unwrap();
        let sentinel = root.join("must-not-exist");
        let source = root.join(format!(
            "Axo's \"$(touch {})\"`touch {}`\\test\n.app/Contents/Helpers/axo",
            sentinel.display(),
            sentinel.display()
        ));
        let asked = std::cell::RefCell::new(Vec::new());
        let ran = |script: &str| {
            asked.borrow_mut().push(script.to_owned());
            finished(0, "")
        };
        // `install` checks the link itself once the script has run.
        assert!(authorize(&source, &ran).is_ok());
        let asked = asked.into_inner();
        assert_eq!(asked.len(), 1, "authorization asks once");

        let command = applescript_literal(&asked[0]);
        let arguments = command
            .strip_prefix("/usr/bin/osascript ")
            .expect("the shell runs osascript by its full path");
        let printed = std::process::Command::new("/bin/sh")
            .args(["-c", &format!("printf '%s\\0' {arguments}")])
            .output()
            .unwrap();
        assert!(printed.status.success(), "{printed:?}");
        let printed = String::from_utf8(printed.stdout).unwrap();
        let printed: Vec<&str> = printed.strip_suffix('\0').unwrap().split('\0').collect();
        let javascript = filesystem_script(&source, Path::new(SYSTEM_DIRECTORY)).unwrap();
        assert_eq!(printed, ["-l", "JavaScript", "-e", javascript.as_str()]);
        assert!(!sentinel.exists(), "the shell ran part of the app location");

        let constant = |name: &str| -> String {
            let line = javascript
                .lines()
                .find_map(|line| line.strip_prefix(&format!("const {name} = ")))
                .unwrap();
            serde_json::from_str(line.strip_suffix(';').unwrap()).unwrap()
        };
        assert_eq!(Path::new(&constant("source")), source);
        assert_eq!(constant("directory"), SYSTEM_DIRECTORY);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn authorization_failures_say_what_went_wrong() {
        // Not this Mac's Axo: a failure with the link already in place is a success.
        let root = temporary_root("authorization");
        let source = &root.join("Axo.app/Contents/Helpers/axo");
        let message = |stderr: &'static str| match authorize(source, &|_| finished(1, stderr)) {
            Err(failure) => failure.message,
            Ok(()) => panic!("a failed authorization succeeded"),
        };
        assert!(
            message("execution error: Error: AXO_CLI_LINK_FAILED (-2700)")
                .contains("check for another file or link there")
        );
        assert!(message("User canceled. (-128)").contains("cancelled"));
        assert!(message("anything else").contains("choose a user bin directory"));
        let refused = authorize(source, &|_| Err(io::ErrorKind::NotFound.into()));
        assert!(refused.is_err());
    }

    /// The script against a real filesystem, by hand: it runs osascript, which a Mac's
    /// security software may kill (`cargo test -- --ignored`).
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "runs osascript; the hermetic tests above check the script"]
    fn os_filesystem_script_is_literal_idempotent_and_refuses_every_existing_entry_kind() {
        let root = std::env::temp_dir().join(format!(
            "axo-cli-script-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let sentinel = root.join("must-not-exist");
        let source = root.join(format!(
            "Axo's \"$(touch {})\"\\test\n.app/Contents/Helpers/axo",
            sentinel.display()
        ));
        let directory = root.join("bin");
        let link = directory.join("axo");
        let javascript = filesystem_script(&source, &directory).unwrap();
        let shell = format!(
            "/usr/bin/osascript -l JavaScript -e {}",
            shell_quote(&javascript)
        );
        // Execute the production parser/quoting layers WITHOUT administrator authorization,
        // always against a new temporary directory. No user's PATH or profile is touched.
        let run = || {
            std::process::Command::new("/usr/bin/osascript")
                .args([
                    "-e",
                    &format!("do shell script {}", applescript_quote(&shell)),
                ])
                .output()
                .unwrap()
        };
        let first = run();
        assert!(
            first.status.success(),
            "{}",
            String::from_utf8_lossy(&first.stderr)
        );
        assert!(same_link(&link, &source));
        assert!(run().status.success());
        std::fs::remove_file(&link).unwrap();
        std::fs::write(&link, "foreign executable").unwrap();
        assert!(!run().status.success());
        assert_eq!(
            std::fs::read_to_string(&link).unwrap(),
            "foreign executable"
        );
        std::fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink("/missing/foreign", &link).unwrap();
        assert!(!run().status.success());
        assert_eq!(
            std::fs::read_link(&link).unwrap(),
            Path::new("/missing/foreign")
        );
        std::fs::remove_file(&link).unwrap();
        std::fs::create_dir(&link).unwrap();
        assert!(!run().status.success());
        assert_eq!(
            std::fs::read_dir(&link).unwrap().count(),
            0,
            "never create a nested link inside a destination directory"
        );
        assert!(!sentinel.exists());
        std::fs::remove_dir_all(&root).unwrap();
    }
    #[test]
    fn app_replacement_updates_the_link_without_reinstalling() {
        let root = std::env::temp_dir().join(format!(
            "axo-cli-replacement-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let source = root.join("helper");
        let directory = root.join("bin");
        std::fs::write(&source, "first build").unwrap();
        create_link(&source, &directory).unwrap();
        let replacement = root.join("new-helper");
        std::fs::write(&replacement, "new build").unwrap();
        std::fs::rename(&replacement, &source).unwrap();
        assert_eq!(
            std::fs::read_to_string(directory.join("axo")).unwrap(),
            "new build"
        );
        create_link(&source, &directory).unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn script_literals_escape_applescript_metacharacters() {
        assert_eq!(applescript_quote("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"");
        assert_eq!(shell_quote("a'b"), "'a'\\''b'");
    }
}

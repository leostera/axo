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
fn authorize(source: &Path) -> Result<(), Failure> {
    let script = authorization_script(source)?;
    let result = std::process::Command::new("/usr/bin/osascript")
        .args(["-e", &script])
        .output()?;
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
            authorize(&executable)?
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
    #[cfg(target_os = "macos")]
    #[test]
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

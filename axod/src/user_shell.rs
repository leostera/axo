//! Captured user-login shell policy. Local pane callers never supply cwd or argv.
use crate::{model::TerminalLaunch, work::valid_directory_id};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, CString},
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovedShellProfile(String);

/// Wire/storage representation remains an approved profile string, or null for
/// the captured user login shell. These choices have distinct receipt intents.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "Option<String>", into = "Option<String>")]
pub enum ShellSource {
    #[default]
    UserLogin,
    Approved(ApprovedShellProfile),
}
impl TryFrom<Option<String>> for ShellSource {
    type Error = &'static str;
    fn try_from(value: Option<String>) -> Result<Self, Self::Error> {
        match value {
            None => Ok(Self::UserLogin),
            Some(id) if valid_directory_id(&id) => Ok(Self::Approved(ApprovedShellProfile(id))),
            Some(_) => Err("Invalid approved shell profile"),
        }
    }
}
impl From<ShellSource> for Option<String> {
    fn from(value: ShellSource) -> Self {
        match value {
            ShellSource::UserLogin => None,
            ShellSource::Approved(ApprovedShellProfile(id)) => Some(id),
        }
    }
}
impl ApprovedShellProfile {
    pub(crate) fn id(&self) -> &str {
        &self.0
    }
}

/// Boot-captured executable identity, not a request-selected command or fallback.
pub(crate) struct CapturedUserShell {
    executable: PathBuf,
    device: u64,
    inode: u64,
}
impl CapturedUserShell {
    pub(crate) fn capture() -> Option<Self> {
        // A present but invalid SHELL is an unavailable policy, not permission to
        // silently substitute another executable. Only absence consults passwd.
        let selected = match std::env::var_os("SHELL") {
            Some(value) => PathBuf::from(value),
            None => account_shell()?,
        };
        Self::parse(&selected)
    }
    /// A LaunchAgent's SHELL may describe launchd or a GUI launcher, not the
    /// user's configured login shell. serve-user captures the account authority.
    pub(crate) fn capture_account() -> Option<Self> {
        Self::parse(&account_shell()?)
    }
    pub(crate) fn executable(&self) -> &std::ffi::OsStr {
        self.executable.as_os_str()
    }
    pub(crate) fn parse(selected: &Path) -> Option<Self> {
        if !selected.is_absolute() {
            return None;
        }
        let executable = fs::canonicalize(selected).ok()?;
        let text = executable.to_str()?;
        if text.len() > 4096 || text.contains('\0') {
            return None;
        }
        let metadata = fs::metadata(&executable).ok()?;
        let path = CString::new(text).ok()?;
        if !metadata.is_file() || unsafe { libc::access(path.as_ptr(), libc::X_OK) } != 0 {
            return None;
        }
        Some(Self {
            executable,
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
    pub(crate) fn launch(&self, directory: &Path) -> Option<TerminalLaunch> {
        let current = Self::parse(&self.executable)?;
        if current.device != self.device
            || current.inode != self.inode
            || fs::canonicalize(directory).ok()?.as_path() != directory
        {
            return None;
        }
        let launch = TerminalLaunch {
            directory: directory.to_str()?.to_owned(),
            argv: vec![self.executable.to_str()?.to_owned(), "-l".into()],
        };
        crate::pty::validate_launch(&launch.directory, &launch.argv).ok()?;
        Some(launch)
    }
}
fn account_shell() -> Option<PathBuf> {
    let mut record: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0_u8; 16 * 1024];
    let status = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut record,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() || record.pw_shell.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(record.pw_shell) }.to_str().ok()?;
    Some(PathBuf::from(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn shell_sources_are_closed_distinct_and_preserve_existing_profile_encoding() {
        let configured: ShellSource = serde_json::from_str("\"shell\"").unwrap();
        assert_eq!(serde_json::to_string(&configured).unwrap(), "\"shell\"");
        assert_eq!(
            serde_json::from_str::<ShellSource>("null").unwrap(),
            ShellSource::UserLogin
        );
        assert_ne!(configured, ShellSource::UserLogin);
        for invalid in ["\"\"", "\"../shell\"", "42", "{\"argv\":[\"/bin/sh\"]}"] {
            assert!(serde_json::from_str::<ShellSource>(invalid).is_err());
        }
    }
    #[test]
    fn account_shell_capture_matches_the_configured_login_executable() {
        let expected = fs::canonicalize(account_shell().expect("account shell")).unwrap();
        let captured = CapturedUserShell::capture_account().expect("usable account shell");
        assert_eq!(captured.executable, expected);
    }
    #[test]
    fn captured_shell_rejects_missing_relative_nonexecutable_and_replaced_programs() {
        let root = TestDirectory::new();
        assert!(CapturedUserShell::parse(Path::new("sh")).is_none());
        assert!(CapturedUserShell::parse(root.path()).is_none());
        let executable = root.path().join("shell");
        fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(CapturedUserShell::parse(&executable).is_none());
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let captured = CapturedUserShell::parse(&executable).unwrap();
        let launch = captured
            .launch(&root.path().canonicalize().unwrap())
            .unwrap();
        assert_eq!(
            launch.argv,
            [executable.canonicalize().unwrap().to_str().unwrap(), "-l"]
        );
        let replacement = root.path().join("replacement");
        fs::write(&replacement, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&replacement, fs::Permissions::from_mode(0o700)).unwrap();
        fs::rename(replacement, executable).unwrap();
        assert!(
            captured
                .launch(&root.path().canonicalize().unwrap())
                .is_none()
        );
    }
}

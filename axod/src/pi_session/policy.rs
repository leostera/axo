//! Explicit operator policy, never caller argv/cwd or a bundled Pi launcher.
use crate::{ambient_pi::AmbientPi, private_file::read_private};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs, io,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Profile {
    pub(crate) directory: PathBuf,
    pub(crate) session_directory: PathBuf,
    #[serde(default)]
    pub(crate) executable: Option<PathBuf>,
    #[serde(default)]
    pub(crate) arguments: Vec<String>,
}
#[derive(Clone)]
pub struct Policy {
    pub(crate) extension: PathBuf,
    pub(crate) profiles: BTreeMap<String, Profile>,
    local: Option<LocalPolicy>,
    pub(crate) normal_path: Option<crate::user_path::CapturedPath>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LocalPolicy {
    session_directory: PathBuf,
    #[serde(default)]
    executable: Option<PathBuf>,
    #[serde(default)]
    arguments: Vec<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    extension: PathBuf,
    profiles: BTreeMap<String, Profile>,
    #[serde(default)]
    local: Option<LocalPolicy>,
}
pub(crate) struct ApprovedLaunch {
    pub terminal: crate::model::TerminalLaunch,
    pub sessions: PathBuf,
}
impl Policy {
    pub fn read(path: &Path) -> io::Result<Self> {
        let policy: Document = serde_json::from_slice(&read_private(path, 65536)?)
            .map_err(|_| io::Error::other("Invalid managed Pi policy"))?;
        if !policy.extension.is_absolute()
            || !fs::metadata(&policy.extension)?.is_file()
            || policy.profiles.len() > 16
        {
            return Err(io::Error::other("Invalid Pi extension policy"));
        }
        for (id, profile) in &policy.profiles {
            if id.is_empty()
                || id.len() > 64
                || !id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
                || !profile.directory.is_absolute()
                || !fs::metadata(&profile.directory)?.is_dir()
                || !profile.session_directory.is_absolute()
            {
                return Err(io::Error::other("Invalid Pi profile"));
            }
            let directory = fs::symlink_metadata(&profile.session_directory)?;
            if !directory.is_dir()
                || directory.uid() != unsafe { libc::geteuid() }
                || directory.permissions().mode() & 0o077 != 0
            {
                return Err(io::Error::other(
                    "Pi sessions require an owned private directory",
                ));
            }
            validate_arguments(&profile.arguments)?;
        }
        if let Some(local) = &policy.local {
            validate_sessions(&local.session_directory)?;
            validate_arguments(&local.arguments)?;
        }
        Ok(Self {
            extension: policy.extension,
            profiles: policy.profiles,
            local: policy.local,
            normal_path: None,
        })
    }
    /// The app installs only its adapter, never a Pi engine or replacement launcher.
    pub(crate) fn for_user(extension: PathBuf, root: &Path) -> io::Result<Self> {
        if !extension.is_absolute() || !fs::metadata(&extension)?.is_file() {
            return Err(io::Error::other("Installed Axo extension unavailable"));
        }
        let sessions = root.join("PiSessions");
        match fs::DirBuilder::new().mode(0o700).create(&sessions) {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error),
        }
        validate_sessions(&sessions)?;
        Ok(Self {
            extension,
            profiles: BTreeMap::new(),
            normal_path: None,
            local: Some(LocalPolicy {
                session_directory: sessions,
                executable: None,
                // Vanilla Pi still reads context files, but executable project-local
                // resources need separate approval rather than an unanswerable startup dialog.
                arguments: vec!["--no-approve".into()],
            }),
        })
    }
    pub(crate) fn profile(
        &self,
        approval: &crate::state::DirectoryApproval,
        directory: &Path,
    ) -> io::Result<Profile> {
        match approval {
            crate::state::DirectoryApproval::Profile(id) => self
                .profiles
                .get(id)
                .cloned()
                .ok_or_else(|| io::Error::other("Pi directory profile unavailable")),
            crate::state::DirectoryApproval::LocalSelection
            | crate::state::DirectoryApproval::UserHome => {
                let local = self
                    .local
                    .as_ref()
                    .ok_or_else(|| io::Error::other("Local Pi policy unavailable"))?;
                validate_sessions(&local.session_directory)?;
                Ok(Profile {
                    directory: directory.to_owned(),
                    session_directory: local.session_directory.clone(),
                    executable: local.executable.clone(),
                    arguments: local.arguments.clone(),
                })
            }
        }
    }
    pub(crate) fn launch(
        &self,
        profile: &Profile,
        directory: &Path,
        resume: Option<&Path>,
    ) -> io::Result<ApprovedLaunch> {
        if fs::canonicalize(&profile.directory)? != fs::canonicalize(directory)? {
            return Err(io::Error::other(
                "Work directory no longer approved by Pi policy",
            ));
        }
        let ambient = AmbientPi::find_with_path(
            profile.executable.as_deref(),
            self.normal_path.as_ref().map(|path| path.as_os_str()),
        )
        .map_err(io::Error::other)?;
        let mut argv = vec![
            ambient
                .executable
                .to_str()
                .ok_or_else(|| io::Error::other("Invalid Pi launcher encoding"))?
                .to_owned(),
        ];
        argv.extend(profile.arguments.clone());
        argv.extend([
            "--extension".into(),
            self.extension
                .to_str()
                .ok_or_else(|| io::Error::other("Invalid extension encoding"))?
                .into(),
            "--axo-managed-control".into(),
            "--session-dir".into(),
            profile
                .session_directory
                .to_str()
                .ok_or_else(|| io::Error::other("Invalid session directory encoding"))?
                .into(),
        ]);
        if let Some(file) = resume {
            argv.extend([
                "--session".into(),
                file.to_str()
                    .ok_or_else(|| io::Error::other("Invalid persistence binding"))?
                    .into(),
            ]);
        }
        Ok(ApprovedLaunch {
            terminal: crate::model::TerminalLaunch {
                directory: directory
                    .to_str()
                    .ok_or_else(|| io::Error::other("Invalid directory encoding"))?
                    .into(),
                argv,
            },
            sessions: profile.session_directory.clone(),
        })
    }
}
fn validate_sessions(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !path.is_absolute()
        || !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::other(
            "Pi sessions require an owned private directory",
        ));
    }
    Ok(())
}
fn validate_arguments(arguments: &[String]) -> io::Result<()> {
    if arguments.len() > 64 {
        return Err(io::Error::other("Pi argument capacity"));
    }
    let mut arguments = arguments.iter();
    while let Some(flag) = arguments.next() {
        match flag.as_str() {
            "--no-extensions"
            | "--no-skills"
            | "--no-themes"
            | "--no-context-files"
            | "--no-prompt-templates"
            | "--offline"
            | "--no-approve" => (),
            "--provider" | "--model" | "--thinking" | "--tools" | "--extension" => {
                let value = arguments
                    .next()
                    .ok_or_else(|| io::Error::other("Missing approved Pi argument"))?;
                if value.is_empty()
                    || value.len() > 16384
                    || value.contains('\0')
                    || value.starts_with('-')
                {
                    return Err(io::Error::other("Invalid approved Pi argument"));
                }
            }
            _ => {
                return Err(io::Error::other(
                    "Unsupported Pi policy argument; no prompt or alternate mode",
                ));
            }
        }
    }
    Ok(())
}

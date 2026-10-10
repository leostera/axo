//! Explicit operator policy, never caller argv/cwd or a bundled Pi launcher.
use crate::{ambient_pi::AmbientPi, private_file::read_private};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs, io,
    os::unix::fs::{MetadataExt, PermissionsExt},
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
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Document {
    extension: PathBuf,
    profiles: BTreeMap<String, Profile>,
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
        Ok(Self {
            extension: policy.extension,
            profiles: policy.profiles,
        })
    }
    pub(crate) fn launch(
        &self,
        id: &str,
        directory: &Path,
        resume: Option<&Path>,
    ) -> io::Result<ApprovedLaunch> {
        let profile = self
            .profiles
            .get(id)
            .ok_or_else(|| io::Error::other("Pi directory profile unavailable"))?;
        if fs::canonicalize(&profile.directory)? != fs::canonicalize(directory)? {
            return Err(io::Error::other(
                "Work directory no longer approved by Pi policy",
            ));
        }
        let ambient = AmbientPi::find(profile.executable.as_deref()).map_err(io::Error::other)?;
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

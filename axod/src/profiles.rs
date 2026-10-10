//! Operator-owned execution policy shared by local and cloud RPC adapters.
use crate::{model::TerminalLaunch, private_file::read_private};
use serde::Deserialize;
use std::{collections::BTreeMap, io, path::Path};

#[derive(Clone, Default)]
pub struct Profiles(pub(crate) BTreeMap<String, TerminalLaunch>);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    profiles: BTreeMap<String, TerminalLaunch>,
}
impl Profiles {
    pub fn read(path: &Path) -> io::Result<Self> {
        let config: Configuration = serde_json::from_slice(&read_private(path, 65_536)?)
            .map_err(|_| io::Error::other("Invalid profiles configuration"))?;
        Self::validate(config.profiles)
    }
    pub(crate) fn validate(profiles: BTreeMap<String, TerminalLaunch>) -> io::Result<Self> {
        if profiles.len() > 16
            || profiles.keys().any(|key| {
                key.is_empty()
                    || key.len() > 64
                    || !key
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
            })
        {
            return Err(io::Error::other("Invalid approved profiles"));
        }
        for launch in profiles.values() {
            crate::pty::validate_launch(&launch.directory, &launch.argv)?;
            if launch.directory.contains('\0') || launch.argv.iter().any(|arg| arg.contains('\0')) {
                return Err(io::Error::other("Invalid approved launch"));
            }
        }
        Ok(Self(profiles))
    }
}

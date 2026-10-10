//! Per-user launch-agent entry point for the bundled Axod helper.
use std::{
    fs, io,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};

const SUPPORT_COMPONENTS: [&str; 3] = ["Library", "Application Support", "Axo"];

pub fn serve(instance_id: Option<&str>) -> io::Result<()> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("The launch agent has no user home directory"))?;
    let root = ensure_state_directory(&home, instance_id)?;
    let profiles_path = root.join("profiles.json");
    let pi_path = root.join("pi.json");
    let profiles = read_optional(&profiles_path, crate::profiles::Profiles::read)?;
    let pi = read_optional(&pi_path, crate::PiPolicy::read)?;
    crate::server::serve_with_pi(&root, None, profiles, pi)
}

fn ensure_state_directory(home: &Path, instance_id: Option<&str>) -> io::Result<PathBuf> {
    let home_metadata = fs::symlink_metadata(home)?;
    if !home.is_absolute()
        || !home_metadata.is_dir()
        || home_metadata.file_type().is_symlink()
        || home_metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(io::Error::other(
            "The launch agent home directory is not owned by this user",
        ));
    }

    let mut path = home.to_owned();
    for (index, component) in SUPPORT_COMPONENTS.iter().enumerate() {
        path.push(component);
        ensure_owned_directory(&path, index >= 2)?;
    }
    if let Some(instance_id) = instance_id {
        validate_instance_id(instance_id)?;
        path.push("Instances");
        ensure_owned_directory(&path, true)?;
        path.push(instance_id);
        ensure_owned_directory(&path, true)?;
    }
    path.push("Axod");
    ensure_owned_directory(&path, true)?;
    Ok(path)
}

fn validate_instance_id(value: &str) -> io::Result<()> {
    let valid = !value.is_empty()
        && value.len() <= 32
        && value.split('-').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        });
    if valid {
        Ok(())
    } else {
        Err(io::Error::other("Invalid Axod app instance identifier"))
    }
}

fn ensure_owned_directory(path: &Path, private: bool) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => validate_directory(path, &metadata, private),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            builder.mode(0o700);
            builder.create(path)?;
            let metadata = fs::symlink_metadata(path)?;
            validate_directory(path, &metadata, private)
        }
        Err(error) => Err(error),
    }
}

fn validate_directory(path: &Path, metadata: &fs::Metadata, private: bool) -> io::Result<()> {
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || (private && metadata.permissions().mode() & 0o077 != 0)
    {
        return Err(io::Error::other(format!(
            "Unsafe Axod state directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn read_optional<T>(
    path: &Path,
    read: impl FnOnce(&Path) -> io::Result<T>,
) -> io::Result<Option<T>> {
    match read(path) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;
    use std::os::unix::fs::symlink;

    #[test]
    fn default_state_is_created_private_and_reused() {
        let home = TestDirectory::new();
        let root = ensure_state_directory(home.path(), None).unwrap();
        assert_eq!(
            root,
            home.path().join("Library/Application Support/Axo/Axod")
        );
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(ensure_state_directory(home.path(), None).unwrap(), root);
    }

    #[test]
    fn default_state_rejects_symlinked_or_shared_application_root() {
        let home = TestDirectory::new();
        fs::create_dir(home.path().join("Library")).unwrap();
        fs::create_dir(home.path().join("Library/Application Support")).unwrap();
        let elsewhere = home.path().join("elsewhere");
        fs::create_dir(&elsewhere).unwrap();
        fs::set_permissions(&elsewhere, fs::Permissions::from_mode(0o700)).unwrap();
        symlink(
            &elsewhere,
            home.path().join("Library/Application Support/Axo"),
        )
        .unwrap();
        assert!(ensure_state_directory(home.path(), None).is_err());
    }

    #[test]
    fn instance_state_is_isolated_and_rejects_path_syntax() {
        let home = TestDirectory::new();
        let stable = ensure_state_directory(home.path(), None).unwrap();
        let instance = ensure_state_directory(home.path(), Some("2")).unwrap();
        assert_eq!(
            stable,
            home.path().join("Library/Application Support/Axo/Axod")
        );
        assert_eq!(
            instance,
            home.path()
                .join("Library/Application Support/Axo/Instances/2/Axod")
        );
        assert_ne!(stable, instance);
        assert!(ensure_state_directory(home.path(), Some("../shared")).is_err());
        assert!(ensure_state_directory(home.path(), Some("Preview")).is_err());
    }
}

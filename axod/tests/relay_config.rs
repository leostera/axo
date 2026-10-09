//! Private fixtures only: these tests neither connect to a relay nor inspect live state.
use axod::relay::{Config, machine_id};
use serde_json::{Value, json};
use std::{
    fs::{self, DirBuilder, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt, symlink},
    path::PathBuf,
};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("axod-relay-test-{}", uuid::Uuid::new_v4()));
        DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn config(&self, input: &Value) -> PathBuf {
        let path = self.0.join(format!("{}.json", uuid::Uuid::new_v4()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.write_all(&serde_json::to_vec(input).unwrap()).unwrap();
        path
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn valid() -> Value {
    json!({"relay_url":"wss://api.axo.leostera.dev/", "label":"Test fixture", "credentials":{"kind":"access_assertion","assertion":"fixture-only"}})
}

#[test]
fn configuration_rejects_insecure_routes_ambiguous_urls_and_bad_credentials() {
    let directory = Directory::new();
    assert!(Config::read(&directory.config(&valid())).is_ok());
    for url in [
        "ws://api.axo.leostera.dev/",
        "ws://localhost/",
        "ws://192.0.2.1/",
        "wss://user:password@example.com/",
        "wss://example.com/?token=secret",
        "wss://example.com/#fragment",
        "wss://example.com/path",
    ] {
        let mut input = valid();
        input["relay_url"] = json!(url);
        input["allow_insecure_loopback"] = json!(true);
        assert!(Config::read(&directory.config(&input)).is_err(), "{url}");
    }
    for url in ["ws://127.0.0.1:12345/", "ws://[::1]:12345/"] {
        let mut input = valid();
        input["relay_url"] = json!(url);
        input["allow_insecure_loopback"] = json!(true);
        assert!(Config::read(&directory.config(&input)).is_ok());
    }
    for credential in [
        String::new(),
        "has\na\nnewline".to_owned(),
        "x".repeat(8193),
    ] {
        let mut input = valid();
        input["credentials"]["assertion"] = json!(credential);
        assert!(Config::read(&directory.config(&input)).is_err());
    }
}
#[test]
fn private_configuration_rejects_symlinks_hardlinks_and_public_modes() {
    let directory = Directory::new();
    let path = directory.config(&valid());
    let alias = directory.0.join("alias");
    symlink(&path, &alias).unwrap();
    assert!(Config::read(&alias).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(Config::read(&path).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    fs::hard_link(&path, directory.0.join("hardlink")).unwrap();
    assert!(Config::read(&path).is_err());
    assert!(Config::read(std::path::Path::new("relative.json")).is_err());
}
#[test]
fn machine_identity_is_stable_and_corruption_never_regenerates_it() {
    let directory = Directory::new();
    let first = machine_id(&directory.0).unwrap();
    assert_eq!(first, machine_id(&directory.0).unwrap());
    let path = directory.0.join("machine-id.json");
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    fs::write(&path, b"partial identity").unwrap();
    assert!(machine_id(&directory.0).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"partial identity");
}

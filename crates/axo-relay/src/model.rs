//! What kind of Mac this is, for the account to show it by: a Mac Studio is not a MacBook.

use std::sync::OnceLock;

use serde::Serialize;

/// This Mac's model: its identifier (`hw.model`, "Mac13,2") and, where macOS knows it, the
/// model's name ("Mac Studio", "MacBook Pro (14-inch, Nov 2024)"). `HostModel` in
/// `common.schema.json`.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct HostModel {
    pub identifier: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// This Mac's model, read once: it does not change while axod runs. None when macOS does not
/// say, and the account then shows a Mac.
pub fn host_model() -> Option<HostModel> {
    static MODEL: OnceLock<Option<HostModel>> = OnceLock::new();
    MODEL
        .get_or_init(|| {
            let identifier = sysctl_string(c"hw.model").filter(|id| is_identifier(id))?;
            Some(HostModel {
                identifier,
                name: product_name(),
            })
        })
        .clone()
}

/// A model identifier as the account takes one: "Mac13,2", "MacBookPro18,3".
fn is_identifier(identifier: &str) -> bool {
    let mut characters = identifier.chars();
    identifier.len() <= 64
        && characters
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
        && characters.all(|c| c.is_ascii_alphanumeric() || c == ',')
}

fn sysctl_string(name: &std::ffi::CStr) -> Option<String> {
    let mut bytes = [0_u8; 128];
    let mut length = bytes.len();
    // SAFETY: bytes is writable storage of `length` bytes, and sysctlbyname writes at most that
    // many, telling how many it wrote in `length`.
    let status = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            bytes.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 {
        return None;
    }
    let text = &bytes[..length.min(bytes.len())];
    let text = text.split(|byte| *byte == 0).next().unwrap_or_default();
    String::from_utf8(text.to_vec()).ok()
}

/// The model's name, as the device tree has it; Apple silicon Macs have one, Intel ones do not.
fn product_name() -> Option<String> {
    let output = std::process::Command::new("/usr/sbin/ioreg")
        .args(["-rd1", "-k", "product-name", "-p", "IODeviceTree"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    output.status.success().then_some(())?;
    parse_product_name(&String::from_utf8_lossy(&output.stdout))
}

/// `"product-name" = <"Mac Studio">` in what `ioreg` prints.
fn parse_product_name(listing: &str) -> Option<String> {
    let line = listing
        .lines()
        .find(|line| line.contains("\"product-name\""))?;
    let start = line.find("<\"")? + 2;
    let end = line.rfind("\">")?;
    let name = line.get(start..end)?.trim_end_matches('\0').trim();
    (!name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control))
        .then(|| name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::{HostModel, host_model, is_identifier, parse_product_name};

    #[test]
    fn a_model_name_is_read_from_what_ioreg_prints() {
        let listing = "+-o Root  <class IORegistryEntry>\n  {\n    \"model\" = <\"Mac13,2\">\n      \"product-name\" = <\"Mac Studio\">\n  }\n";
        assert_eq!(parse_product_name(listing).as_deref(), Some("Mac Studio"));
        let laptop = "      \"product-name\" = <\"MacBook Pro (14-inch, Nov 2024)\">";
        assert_eq!(
            parse_product_name(laptop).as_deref(),
            Some("MacBook Pro (14-inch, Nov 2024)")
        );
        assert_eq!(parse_product_name("    \"model\" = <\"Mac13,2\">"), None);
        assert_eq!(parse_product_name("    \"product-name\" = <\"\">"), None);
    }

    #[test]
    fn only_a_model_identifier_is_one() {
        assert!(is_identifier("Mac13,2"));
        assert!(is_identifier("MacBookPro18,3"));
        assert!(!is_identifier(""));
        assert!(!is_identifier("13,2"));
        assert!(!is_identifier("<script>"));
    }

    #[test]
    fn it_is_sent_as_the_schema_says() {
        let model = HostModel {
            identifier: "Mac13,2".into(),
            name: Some("Mac Studio".into()),
        };
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../schemas/axo.leostera.dev/v1/fixtures/host-register.call.json"
        ))
        .unwrap();
        assert_eq!(
            serde_json::to_value(&model).unwrap(),
            fixture["params"]["model"]
        );
        let bare = HostModel {
            identifier: "MacBookPro16,1".into(),
            name: None,
        };
        assert_eq!(
            serde_json::to_value(&bare).unwrap(),
            serde_json::json!({ "identifier": "MacBookPro16,1" })
        );
    }

    #[test]
    fn this_mac_knows_its_model() {
        let model = host_model().expect("macOS says what this Mac is");
        assert!(is_identifier(&model.identifier), "{model:?}");
    }
}

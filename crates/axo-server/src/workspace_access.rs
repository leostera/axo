use std::io;
use std::path::{Path, PathBuf};

#[cfg(target_os = "macos")]
use core_foundation::base::{TCFType, kCFAllocatorDefault};
#[cfg(target_os = "macos")]
use core_foundation::data::CFData;
#[cfg(target_os = "macos")]
use core_foundation::url::{
    CFURL, CFURLCreateByResolvingBookmarkData, CFURLStartAccessingSecurityScopedResource,
    CFURLStopAccessingSecurityScopedResource, kCFURLBookmarkResolutionWithSecurityScope,
    kCFURLBookmarkResolutionWithoutUIMask,
};

pub(crate) struct WorkspaceDirectoryAccess {
    path: PathBuf,
    #[cfg(target_os = "macos")]
    _scoped_url: Option<ScopedURL>,
}

impl WorkspaceDirectoryAccess {
    pub(crate) fn open(path: &Path, bookmark: Option<&str>) -> io::Result<Self> {
        let canonical_path = path.canonicalize();
        #[cfg(target_os = "macos")]
        {
            match canonical_path {
                Ok(canonical_path) => {
                    if !canonical_path.is_dir() {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "Workspace root must be a directory",
                        ));
                    }
                    let scoped_url = bookmark
                        .filter(|bookmark| !bookmark.is_empty())
                        .and_then(|bookmark| Self::open_scoped(path, bookmark).ok())
                        .filter(|access| access.path == canonical_path)
                        .and_then(|access| access._scoped_url);
                    Ok(Self {
                        path: canonical_path,
                        _scoped_url: scoped_url,
                    })
                }
                Err(path_error) => match bookmark.filter(|bookmark| !bookmark.is_empty()) {
                    Some(bookmark) => Self::open_scoped(path, bookmark),
                    None => Err(path_error),
                },
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let path = canonical_path?;
            if !path.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Workspace root must be a directory",
                ));
            }
            Ok(Self { path })
        }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    #[cfg(target_os = "macos")]
    fn open_scoped(path: &Path, bookmark: &str) -> io::Result<Self> {
        let bookmark = decode_bookmark(bookmark)?;
        let bookmark_data = CFData::from_buffer(&bookmark);
        let mut stale = 0;
        // SAFETY: the bookmark data and output pointer are valid for the duration of this call.
        let resolved_url = unsafe {
            CFURLCreateByResolvingBookmarkData(
                kCFAllocatorDefault,
                bookmark_data.as_concrete_TypeRef(),
                kCFURLBookmarkResolutionWithSecurityScope | kCFURLBookmarkResolutionWithoutUIMask,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut stale,
                std::ptr::null_mut(),
            )
        };
        if resolved_url.is_null() {
            return Err(invalid_bookmark());
        }
        // SAFETY: Core Foundation returned an owned CFURL reference.
        let scoped_url = unsafe { CFURL::wrap_under_create_rule(resolved_url) };
        // SAFETY: scoped_url is a valid file URL returned by bookmark resolution.
        let started = unsafe {
            CFURLStartAccessingSecurityScopedResource(scoped_url.as_concrete_TypeRef()) != 0
        };
        let selected_path = scoped_url.to_path().ok_or_else(invalid_bookmark)?;
        let selected_path = selected_path
            .canonicalize()
            .map_err(|error| scoped_access_error(error, started))?;
        let requested_path = path
            .canonicalize()
            .map_err(|error| scoped_access_error(error, started))?;
        if selected_path != requested_path {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace path does not match the folder selected in the file browser",
            ));
        }
        if !selected_path.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace root must be a directory",
            ));
        }

        Ok(Self {
            path: selected_path,
            _scoped_url: Some(ScopedURL {
                url: scoped_url,
                started,
            }),
        })
    }
}

#[cfg(target_os = "macos")]
struct ScopedURL {
    url: CFURL,
    started: bool,
}

#[cfg(target_os = "macos")]
unsafe impl Send for ScopedURL {}

#[cfg(target_os = "macos")]
impl Drop for ScopedURL {
    fn drop(&mut self) {
        if self.started {
            // SAFETY: the URL was successfully started and remains retained in this wrapper.
            unsafe { CFURLStopAccessingSecurityScopedResource(self.url.as_concrete_TypeRef()) };
        }
    }
}

#[cfg(target_os = "macos")]
fn scoped_access_error(error: io::Error, scope_started: bool) -> io::Error {
    if !scope_started
        && matches!(
            error.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
        )
    {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Axo cannot access the selected folder; choose it again in the folder picker",
        )
    } else {
        error
    }
}

#[cfg(target_os = "macos")]
fn decode_bookmark(encoded: &str) -> io::Result<Vec<u8>> {
    let invalid = invalid_bookmark();
    let bytes = encoded.as_bytes();
    if bytes.is_empty() || bytes.len() > 65_536 || !bytes.len().is_multiple_of(4) {
        return Err(invalid);
    }

    let mut decoded = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, chunk) in bytes.as_chunks::<4>().0.iter().enumerate() {
        let is_last = index + 1 == bytes.len() / 4;
        let a = base64_value(chunk[0]).ok_or_else(invalid_bookmark)?;
        let b = base64_value(chunk[1]).ok_or_else(invalid_bookmark)?;
        let c = if chunk[2] == b'=' {
            if !is_last || chunk[3] != b'=' || b & 0x0f != 0 {
                return Err(invalid);
            }
            None
        } else {
            Some(base64_value(chunk[2]).ok_or_else(invalid_bookmark)?)
        };
        let d = if chunk[3] == b'=' {
            if !is_last || c.is_none() {
                return Err(invalid);
            }
            None
        } else {
            Some(base64_value(chunk[3]).ok_or_else(invalid_bookmark)?)
        };

        decoded.push((a << 2) | (b >> 4));
        if let Some(c) = c {
            if d.is_none() && c & 0x03 != 0 {
                return Err(invalid);
            }
            decoded.push((b << 4) | (c >> 2));
            if let Some(d) = d {
                decoded.push((c << 6) | d);
            }
        }
    }
    Ok(decoded)
}

#[cfg(target_os = "macos")]
fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn invalid_bookmark() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "selected folder could not be resolved; choose it again in the folder picker",
    )
}

#[cfg(test)]
mod tests {
    use super::WorkspaceDirectoryAccess;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn accessible_directory_does_not_require_a_bookmark() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "axo-workspace-access-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir(&directory).unwrap();

        let access = WorkspaceDirectoryAccess::open(&directory, None).unwrap();
        assert_eq!(access.path(), directory.canonicalize().unwrap());

        drop(access);
        std::fs::remove_dir(&directory).unwrap();
    }
}

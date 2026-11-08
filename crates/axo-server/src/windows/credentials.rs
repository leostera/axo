//! Windows DPAPI protects the relay secret for this Windows account. The containing
//! directory also inherits the daemon's user-and-SYSTEM-only ACL.
use axo_relay::credential::HostCredentialStore;
use std::{io, path::PathBuf, ptr};

#[repr(C)]
struct Blob {
    length: u32,
    data: *mut u8,
}
#[link(name = "crypt32")]
unsafe extern "system" {
    fn CryptProtectData(
        input: *const Blob,
        description: *const u16,
        entropy: *const Blob,
        reserved: *mut core::ffi::c_void,
        prompt: *mut core::ffi::c_void,
        flags: u32,
        output: *mut Blob,
    ) -> i32;
    fn CryptUnprotectData(
        input: *const Blob,
        description: *mut *mut u16,
        entropy: *const Blob,
        reserved: *mut core::ffi::c_void,
        prompt: *mut core::ffi::c_void,
        flags: u32,
        output: *mut Blob,
    ) -> i32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn LocalFree(memory: *mut core::ffi::c_void) -> *mut core::ffi::c_void;
}

pub(super) struct Credentials(pub PathBuf);
impl Credentials {
    fn path(&self, id: &str) -> io::Result<PathBuf> {
        if !axo_protocol::is_uuid(id) {
            return Err(super::invalid("Invalid credential ID"));
        }
        Ok(self.0.join(format!("{id}.dpapi")))
    }
}
fn transform(bytes: &[u8], encrypt: bool) -> io::Result<Vec<u8>> {
    let input = Blob {
        length: bytes
            .len()
            .try_into()
            .map_err(|_| super::invalid("Credential too large"))?,
        data: bytes.as_ptr().cast_mut(),
    };
    let mut output = Blob {
        length: 0,
        data: ptr::null_mut(),
    };
    // CRYPTPROTECT_UI_FORBIDDEN: no unattended credential operation can open a dialog.
    let ok = unsafe {
        if encrypt {
            CryptProtectData(
                &input,
                ptr::null(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                1,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                1,
                &mut output,
            )
        }
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    let value = unsafe { std::slice::from_raw_parts(output.data, output.length as usize).to_vec() };
    if !encrypt {
        unsafe {
            std::ptr::write_bytes(output.data, 0, output.length as usize);
        }
    }
    unsafe {
        LocalFree(output.data.cast());
    }
    Ok(value)
}
impl HostCredentialStore for Credentials {
    fn store(&self, id: &str, secret: &[u8]) -> io::Result<()> {
        let path = self.path(id)?;
        std::fs::create_dir_all(&self.0)?;
        let encrypted = transform(secret, true)?;
        use std::io::Write;
        let temporary = path.with_extension("tmp");
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(&encrypted)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(temporary, path)
    }
    fn load(&self, id: &str) -> io::Result<Vec<u8>> {
        transform(&std::fs::read(self.path(id)?)?, false)
    }
    fn delete(&self, id: &str) -> io::Result<()> {
        match std::fs::remove_file(self.path(id)?) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dpapi_round_trip_and_tamper_rejection() {
        let sealed = transform(b"private relay secret", true).unwrap();
        assert!(!sealed.windows(20).any(|s| s == b"private relay secret"));
        assert_eq!(transform(&sealed, false).unwrap(), b"private relay secret");
        assert!(transform(b"not a DPAPI blob", false).is_err());
    }
}

//! The Windows equivalent of private Unix asset permissions: current user and SYSTEM only.
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree};
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

fn current_sid() -> io::Result<String> {
    // SAFETY: the token is owned until closed; aligned storage lives until its SID is copied.
    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut needed = 0;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
        let mut storage = vec![0_usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            storage.as_mut_ptr().cast(),
            needed,
            &mut needed,
        );
        let error = io::Error::last_os_error();
        CloseHandle(token);
        if ok == 0 {
            return Err(error);
        }
        let user = &*(storage.as_ptr().cast::<TOKEN_USER>());
        let mut text = std::ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut length = 0;
        while *text.add(length) != 0 {
            length += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
        LocalFree(text.cast());
        Ok(sid)
    }
}

#[cfg(test)]
pub(super) fn assert_private(path: &Path) {
    use std::ffi::c_void;
    struct Descriptor(*mut c_void);
    impl Drop for Descriptor {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }
    let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // SAFETY: GetNamedSecurityInfoW owns the descriptor until its guard drops; every ACE
    // and SID is inspected only within that descriptor's lifetime.
    unsafe {
        let mut descriptor = std::ptr::null_mut();
        let mut dacl = std::ptr::null_mut();
        assert_eq!(
            GetNamedSecurityInfoW(
                name.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut dacl,
                std::ptr::null_mut(),
                &mut descriptor
            ),
            0
        );
        let _descriptor = Descriptor(descriptor);
        let mut control = 0;
        let mut revision = 0;
        assert_ne!(
            GetSecurityDescriptorControl(descriptor, &mut control, &mut revision),
            0
        );
        assert_ne!(
            control & SE_DACL_PROTECTED,
            0,
            "private ACL must not inherit other users' grants"
        );
        assert!(!dacl.is_null(), "a null DACL grants everyone access");
        assert_eq!((*dacl).AceCount, 2);
        let mut readers = Vec::new();
        for index in 0..u32::from((*dacl).AceCount) {
            let mut ace = std::ptr::null_mut();
            assert_ne!(GetAce(dacl, index, &mut ace), 0);
            let allowed = &*ace.cast::<ACCESS_ALLOWED_ACE>();
            assert_eq!(
                allowed.Header.AceType, 0,
                "only explicit allow entries are expected"
            );
            assert_eq!(allowed.Mask, 0x001f01ff, "FILE_ALL_ACCESS");
            let mut sid = std::ptr::null_mut();
            assert_ne!(
                ConvertSidToStringSidW(
                    std::ptr::addr_of!(allowed.SidStart).cast_mut().cast(),
                    &mut sid
                ),
                0
            );
            let mut length = 0;
            while *sid.add(length) != 0 {
                length += 1;
            }
            readers.push(String::from_utf16_lossy(std::slice::from_raw_parts(
                sid, length,
            )));
            LocalFree(sid.cast());
        }
        readers.sort();
        let mut expected = vec![current_sid().unwrap(), "S-1-5-18".to_owned()];
        expected.sort();
        assert_eq!(
            readers, expected,
            "only the current user and SYSTEM may access assets"
        );
    }
}

/// Protects an existing file or folder. New cache entries inherit their protected parent's ACL.
pub(super) fn protect(path: &Path, directory: bool) -> io::Result<()> {
    let sid = current_sid()?;
    let inheritance = if directory { "OICI" } else { "" };
    let sddl = format!("D:P(A;{inheritance};FA;;;{sid})(A;{inheritance};FA;;;SY)");
    let sddl: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    let mut name: Vec<u16> = path.as_os_str().encode_wide().collect();
    if name.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Asset path contains NUL",
        ));
    }
    name.push(0);
    // SAFETY: Windows allocates the descriptor; all pointers remain valid until SetNamedSecurityInfoW
    // has copied its DACL. LocalFree runs on every outcome after allocation.
    unsafe {
        let mut descriptor = std::ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let mut present = 0;
        let mut defaulted = 0;
        let mut dacl = std::ptr::null_mut();
        let result = if GetSecurityDescriptorDacl(
            descriptor,
            &mut present,
            &mut dacl,
            &mut defaulted,
        ) == 0
        {
            Err(io::Error::last_os_error())
        } else {
            let code = SetNamedSecurityInfoW(
                name.as_mut_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                dacl,
                std::ptr::null_mut(),
            );
            if code == 0 {
                Ok(())
            } else {
                Err(io::Error::from_raw_os_error(code as i32))
            }
        };
        LocalFree(descriptor);
        result
    }
}

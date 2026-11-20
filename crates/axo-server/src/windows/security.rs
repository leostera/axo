//! Per-user pipe and catalog permissions, using the Windows token rather than a display name.
use std::ffi::c_void;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree};
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

/// Kernel identity used when walking a caller's ancestry. Creation time prevents
/// a recycled PID from inheriting another process's Session authority.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ProcessIdentity {
    pub pid: u32,
    created: u64,
}

impl ProcessIdentity {
    pub fn of(pid: u32) -> Option<Self> {
        use windows_sys::Win32::System::Threading::{
            GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        };
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if process.is_null() {
                return None;
            }
            let mut created = std::mem::zeroed();
            let mut exited = std::mem::zeroed();
            let mut kernel = std::mem::zeroed();
            let mut user = std::mem::zeroed();
            let ok = GetProcessTimes(process, &mut created, &mut exited, &mut kernel, &mut user);
            CloseHandle(process);
            (ok != 0).then_some(Self {
                pid,
                created: (u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime),
            })
        }
    }

    pub fn is_running(self) -> bool {
        Self::of(self.pid) == Some(self)
    }

    /// Read the parent from the same kernel process, rejecting a parent PID
    /// that was reused after this child started.
    pub fn parent(self) -> Option<Self> {
        use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
        #[repr(C)]
        struct BasicInformation {
            exit_status: usize,
            peb: usize,
            affinity: usize,
            priority: usize,
            pid: usize,
            parent: usize,
        }
        #[link(name = "ntdll")]
        unsafe extern "system" {
            fn NtQueryInformationProcess(process: *mut c_void, class: u32,
                information: *mut c_void, length: u32, returned: *mut u32) -> i32;
        }
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, self.pid);
            if process.is_null() { return None; }
            let mut info: BasicInformation = std::mem::zeroed();
            let status = NtQueryInformationProcess(process, 0,
                (&mut info as *mut BasicInformation).cast(),
                std::mem::size_of::<BasicInformation>() as u32, std::ptr::null_mut());
            CloseHandle(process);
            if status < 0 || !self.is_running() { return None; }
            let parent = Self::of(u32::try_from(info.parent).ok()?)?;
            (parent.created <= self.created && parent != self).then_some(parent)
        }
    }
}

#[cfg(test)]
mod identity_tests {
    use super::ProcessIdentity;

    #[test]
    fn process_authority_includes_kernel_creation_time() {
        let current = ProcessIdentity::of(std::process::id()).unwrap();
        assert!(current.is_running());
        assert!(current.parent().is_some());
        let stale = ProcessIdentity { created: current.created + 1, ..current };
        assert!(!stale.is_running());
        assert!(stale.parent().is_none());
        assert!(ProcessIdentity::of(u32::MAX).is_none());
    }
}

/// A local tool process cannot answer its own questions or grant itself access.
/// Match the connected process to this bundle's desktop executable, rather than
/// trusting a role supplied in JSON. The pipe ACL already verifies the user SID.
pub fn is_desktop_client(pipe: &NamedPipeServer) -> bool {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
    };
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetNamedPipeClientProcessId(pipe: *mut c_void, pid: *mut u32) -> i32;
    }
    unsafe {
        let mut pid = 0;
        if GetNamedPipeClientProcessId(pipe.as_raw_handle(), &mut pid) == 0 {
            return false;
        }
        let Some(identity) = ProcessIdentity::of(pid) else {
            return false;
        };
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return false;
        }
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, path.as_mut_ptr(), &mut length);
        CloseHandle(process);
        if ok == 0 {
            return false;
        }
        let actual = std::path::PathBuf::from(String::from_utf16_lossy(&path[..length as usize]));
        let expected = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.join("Axo.exe")));
        match (
            std::fs::canonicalize(actual),
            expected.and_then(|p| std::fs::canonicalize(p).ok()),
        ) {
            (Ok(actual), Some(expected)) => identity.is_running() && actual
                .to_string_lossy()
                .eq_ignore_ascii_case(&expected.to_string_lossy()),
            _ => false,
        }
    }
}

pub fn process_image(pid: u32) -> io::Result<std::path::PathBuf> {
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
    };
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        let ok = QueryFullProcessImageNameW(process, 0, path.as_mut_ptr(), &mut length);
        let error = io::Error::last_os_error();
        CloseHandle(process);
        if ok == 0 {
            return Err(error);
        }
        Ok(std::path::PathBuf::from(String::from_utf16_lossy(
            &path[..length as usize],
        )))
    }
}

pub fn current_sid() -> io::Result<String> {
    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut needed = 0;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
        // usize storage guarantees sufficient alignment for TOKEN_USER.
        let mut storage = vec![0_usize; (needed as usize).div_ceil(std::mem::size_of::<usize>())];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            storage.as_mut_ptr().cast(),
            needed,
            &mut needed,
        );
        CloseHandle(token);
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        let user = &*(storage.as_ptr().cast::<TOKEN_USER>());
        let mut text = std::ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut len = 0;
        while *text.add(len) != 0 {
            len += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        LocalFree(text.cast());
        Ok(sid)
    }
}

struct Descriptor(*mut c_void);
impl Descriptor {
    fn new(sddl: &str) -> io::Result<Self> {
        let wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
        let mut descriptor = std::ptr::null_mut();
        // SAFETY: wide is a terminated SDDL string; descriptor is an out pointer. The result
        // remains allocated for the full Windows call and is freed with LocalFree in Drop.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(),
                1,
                &mut descriptor,
                std::ptr::null_mut(),
            )
        } == 0
        {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(descriptor))
        }
    }
}
impl Drop for Descriptor {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}

pub fn create_pipe(name: &str, sid: &str, first: bool) -> io::Result<NamedPipeServer> {
    let descriptor = Descriptor::new(&format!("O:{sid}D:P(A;;GA;;;{sid})(A;;GA;;;SY)"))?;
    let mut attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };
    // SAFETY: attributes and descriptor are valid until create returns. CreateNamedPipe copies
    // the security descriptor. The pipe rejects network peers and grants only this user/SYSTEM.
    unsafe {
        ServerOptions::new()
            .first_pipe_instance(first)
            .reject_remote_clients(true)
            .create_with_security_attributes_raw(
                name,
                (&mut attributes as *mut SECURITY_ATTRIBUTES).cast(),
            )
    }
}

pub fn protect_directory(path: &Path, sid: &str) -> io::Result<()> {
    let descriptor = Descriptor::new(&format!("D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;SY)"))?;
    let mut dacl = std::ptr::null_mut();
    let mut present = 0;
    let mut defaulted = 0;
    let mut name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    unsafe {
        if GetSecurityDescriptorDacl(descriptor.0, &mut present, &mut dacl, &mut defaulted) == 0 {
            return Err(io::Error::last_os_error());
        }
        let result = SetNamedSecurityInfoW(
            name.as_mut_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            dacl,
            std::ptr::null_mut(),
        );
        if result != 0 {
            return Err(io::Error::from_raw_os_error(result as i32));
        }
    }
    Ok(())
}

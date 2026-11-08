//! One RFC3339 formatter on both host platforms.
pub fn utc_timestamp(unix_millis: i64) -> String {
    let seconds = (unix_millis.max(0) / 1000) as libc::time_t;
    let mut tm = std::mem::MaybeUninit::<libc::tm>::zeroed();
    #[cfg(unix)]
    let failed = unsafe { libc::gmtime_r(&seconds, tm.as_mut_ptr()) }.is_null();
    #[cfg(windows)]
    let failed = unsafe { libc::gmtime_s(tm.as_mut_ptr(), &seconds) } != 0;
    if failed {
        return "1970-01-01T00:00:00.000Z".into();
    }
    let tm = unsafe { tm.assume_init() };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        unix_millis.max(0) % 1000
    )
}

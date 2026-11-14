//! Native dense Qwen inference. This module is compiled only on Apple Silicon.
//! A model stays on its worker thread; MLX stream state is not shared across workers.
use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    marker::PhantomData,
    os::unix::ffi::OsStrExt,
    path::Path,
    ptr::NonNull,
    rc::Rc,
};

unsafe extern "C" {
    fn axo_mlx_initialize(metallib: *const c_char, error: *mut *mut c_char) -> i32;
    fn axo_mlx_load(directory: *const c_char, error: *mut *mut c_char) -> *mut c_void;
    fn axo_mlx_description(model: *mut c_void, error: *mut *mut c_char) -> *mut c_char;
    fn axo_mlx_predict(
        model: *mut c_void,
        inputs: *const c_char,
        error: *mut *mut c_char,
    ) -> *mut c_char;
    fn axo_mlx_free(model: *mut c_void);
    fn axo_mlx_string_free(text: *mut c_char);
}

/// Initialized on, and confined to, one inference worker thread. No native work starts until
/// the packaged Metal resource has been explicitly loaded and a GPU calculation succeeds.
pub struct Runtime {
    _worker_thread: PhantomData<Rc<()>>,
}

/// Owns exactly one native model and cannot outlive its runtime or leave its worker thread.
pub struct Model<'runtime> {
    native: NonNull<c_void>,
    _runtime: &'runtime Runtime,
}

/// Owns a native, NUL-terminated allocation returned by this bridge.
struct NativeString(NonNull<c_char>);

impl NativeString {
    fn take(pointer: *mut c_char) -> Option<Self> {
        NonNull::new(pointer).map(Self)
    }

    fn text(&self) -> String {
        // SAFETY: only bridge-owned terminated strings enter this type.
        unsafe { CStr::from_ptr(self.0.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    }
}

impl Drop for NativeString {
    fn drop(&mut self) {
        // SAFETY: unique ownership, allocated by the matching native allocator.
        unsafe { axo_mlx_string_free(self.0.as_ptr()) };
    }
}

fn diagnostic(pointer: *mut c_char) -> String {
    NativeString::take(pointer)
        .map(|text| text.text())
        .unwrap_or_else(|| "native MLX failed without a diagnostic".into())
}

impl Runtime {
    pub fn new(metallib: &Path) -> Result<Self, String> {
        let path = CString::new(metallib.as_os_str().as_bytes())
            .map_err(|_| "MLX Metal resource path contains a NUL byte")?;
        let mut error = std::ptr::null_mut();
        // SAFETY: the C string and diagnostic out-pointer outlive this synchronous call.
        let initialized = unsafe { axo_mlx_initialize(path.as_ptr(), &mut error) };
        if initialized != 1 {
            return Err(diagnostic(error));
        }
        drop(NativeString::take(error));
        Ok(Self {
            _worker_thread: PhantomData,
        })
    }

    pub fn load(&self, directory: &Path) -> Result<Model<'_>, String> {
        Model::load(self, directory)
    }
}

impl<'runtime> Model<'runtime> {
    fn load(runtime: &'runtime Runtime, directory: &Path) -> Result<Self, String> {
        let directory = CString::new(directory.as_os_str().as_bytes())
            .map_err(|_| "MLX model directory contains a NUL byte")?;
        let mut error = std::ptr::null_mut();
        // SAFETY: directory and the out-pointer remain valid for the synchronous call.
        let pointer = unsafe { axo_mlx_load(directory.as_ptr(), &mut error) };
        let native = NonNull::new(pointer).ok_or_else(|| diagnostic(error))?;
        // The ABI promises no error on success; still reclaim any returned diagnostic.
        drop(NativeString::take(error));
        Ok(Self {
            native,
            _runtime: runtime,
        })
    }

    pub fn description(&self) -> Result<Value, String> {
        self.call(None)
    }

    pub fn predict(&mut self, inputs: &Value) -> Result<Value, String> {
        let input = serde_json::to_string(inputs).map_err(|error| error.to_string())?;
        if input.len() > 1024 * 1024 {
            return Err("MLX prediction input exceeds 1 MiB".into());
        }
        let input = CString::new(input).map_err(|error| error.to_string())?;
        self.call(Some(&input))
    }

    fn call(&self, input: Option<&CStr>) -> Result<Value, String> {
        let mut error = std::ptr::null_mut();
        // SAFETY: self uniquely owns a live model; string and out-pointer outlive the call.
        let pointer = unsafe {
            match input {
                Some(input) => axo_mlx_predict(self.native.as_ptr(), input.as_ptr(), &mut error),
                None => axo_mlx_description(self.native.as_ptr(), &mut error),
            }
        };
        let output = NativeString::take(pointer).ok_or_else(|| diagnostic(error))?;
        drop(NativeString::take(error));
        serde_json::from_str(&output.text())
            .map_err(|error| format!("invalid native MLX response: {error}"))
    }
}

impl Drop for Model<'_> {
    fn drop(&mut self) {
        // SAFETY: unique pointer, dropped once, on its owning worker thread.
        unsafe { axo_mlx_free(self.native.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_nul_path_before_ffi() {
        let path = Path::new(std::ffi::OsStr::from_bytes(b"bad\0path"));
        assert!(Runtime::new(path).err().unwrap().contains("NUL"));
    }

    #[test]
    fn explicit_resource_initialization_and_native_errors_cross_the_rust_boundary() {
        let resource = std::env::var("AXO_TEST_MLX_METALLIB").expect("packaged test resource");
        let path = std::env::current_dir().unwrap().join(resource);
        let runtime = Runtime::new(&path).unwrap();
        let directory = std::env::temp_dir().join(format!("axo-mlx-rust-{}", std::process::id()));
        let builder = std::env::current_dir()
            .unwrap()
            .join(std::env::var("AXO_TEST_MLX_FIXTURE_BUILDER").unwrap());
        let built = std::process::Command::new(builder)
            .arg("--write-fixture")
            .arg(&directory)
            .env("AXO_TEST_MLX_METALLIB", &path)
            .output()
            .expect("native fixture builder");
        assert!(
            built.status.success(),
            "{}",
            String::from_utf8_lossy(&built.stderr)
        );
        {
            let mut model = runtime.load(&directory).unwrap();
            let description = model.description().unwrap();
            assert_eq!(description["model_type"], "qwen3");
            assert_eq!(
                description["runtime_version"],
                crate::build_info().version.unwrap()
            );
            let output = model
                .predict(&serde_json::json!({
                    "input_ids":{"type":"tensor","dtype":"int32","shape":[1,2],"data":[0,1]}
                }))
                .unwrap();
            assert_eq!(output["next_token"]["value"], 2);
            assert!(model.predict(&serde_json::json!({"input_ids": {"type":"tensor","dtype":"int32","shape":[1],"data":[-1]}})).is_err());
        }
        std::fs::remove_dir_all(directory).unwrap();
        assert!(
            runtime
                .load(Path::new("/nonexistent/axo-mlx-test"))
                .is_err()
        );
        assert!(Runtime::new(Path::new("/nonexistent/axo-mlx.metallib")).is_err());
    }
}

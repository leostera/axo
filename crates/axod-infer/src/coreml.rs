//! Direct in-process Core ML embedding. Only include this module on macOS.
//! Native calls may block; the owning inference worker enforces deadlines.

use serde_json::Value;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    marker::PhantomData,
    path::Path,
    ptr::{self, NonNull},
    rc::Rc,
};

const MAX_JSON_BYTES: usize = 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 24 * 1024 * 1024;

unsafe extern "C" {
    fn axo_coreml_probe(error: *mut *mut c_char) -> *mut c_char;
    fn axo_coreml_load(
        path: *const c_char,
        work: *const c_char,
        error: *mut *mut c_char,
    ) -> *mut c_void;
    fn axo_coreml_description(model: *mut c_void, error: *mut *mut c_char) -> *mut c_char;
    fn axo_coreml_predict(
        model: *mut c_void,
        json: *const c_char,
        length: usize,
        error: *mut *mut c_char,
    ) -> *mut c_char;
    fn axo_coreml_free(model: *mut c_void);
    fn axo_coreml_string_free(string: *mut c_char);
}

/// Owns one retained native MLModel. Thread-confined: no Send/Sync promise is
/// made about Core ML or prediction state, and prediction requires exclusive use.
pub struct Model {
    handle: NonNull<c_void>,
    _thread_confined: PhantomData<Rc<()>>,
}

struct NativeString(NonNull<c_char>);
impl NativeString {
    fn text(&self) -> Result<&str, String> {
        // SAFETY: the bridge returns a live malloc-owned NUL-terminated string.
        unsafe { CStr::from_ptr(self.0.as_ptr()) }
            .to_str()
            .map_err(|_| "Core ML returned invalid UTF-8".to_owned())
    }
}
impl Drop for NativeString {
    fn drop(&mut self) {
        // SAFETY: this object exclusively owns this bridge allocation.
        unsafe { axo_coreml_string_free(self.0.as_ptr()) }
    }
}

fn native_result<T>(result: *mut T, error: *mut c_char) -> Result<NonNull<T>, String> {
    if let Some(error) = NonNull::new(error) {
        let error = NativeString(error);
        return Err(error.text()?.to_owned());
    }
    NonNull::new(result).ok_or_else(|| "Core ML call failed without an error message".to_owned())
}

fn native_json(result: *mut c_char, error: *mut c_char) -> Result<Value, String> {
    let result = NativeString(native_result(result, error)?);
    let text = result.text()?;
    if text.len() > MAX_JSON_BYTES {
        return Err("Core ML response exceeds 1 MiB".to_owned());
    }
    serde_json::from_str(text).map_err(|error| format!("invalid Core ML response: {error}"))
}

pub fn probe() -> Result<Value, String> {
    let mut error = ptr::null_mut();
    // SAFETY: error is writable; the bridge returns one owned JSON allocation.
    let result = unsafe { axo_coreml_probe(&mut error) };
    native_json(result, error)
}

impl Model {
    pub fn load(path: &Path, work: &Path) -> Result<Self, String> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        match std::fs::DirBuilder::new().mode(0o700).create(work) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(format!("Core ML work directory: {error}")),
        }
        let metadata = std::fs::symlink_metadata(work).map_err(|error| error.to_string())?;
        if !metadata.is_dir() || metadata.permissions().mode() & 0o077 != 0 {
            return Err("Core ML work directory must be a private, nonsymlink directory".into());
        }
        let work = work.canonicalize().map_err(|error| error.to_string())?;
        let work = CString::new(
            work.to_str()
                .ok_or("Core ML work directory must be UTF-8")?,
        )
        .map_err(|_| "Core ML work path contains NUL")?;
        let path = path
            .canonicalize()
            .map_err(|error| format!("Core ML model path: {error}"))?;
        let path = path.to_str().ok_or("Core ML model path must be UTF-8")?;
        let path = CString::new(path).map_err(|_| "Core ML model path contains NUL")?;
        let mut error = ptr::null_mut();
        // SAFETY: path remains live for this synchronous call; error is writable.
        let handle = unsafe { axo_coreml_load(path.as_ptr(), work.as_ptr(), &mut error) };
        Ok(Self {
            handle: native_result(handle, error)?,
            _thread_confined: PhantomData,
        })
    }

    pub fn description(&self) -> Result<Value, String> {
        let mut error = ptr::null_mut();
        // SAFETY: self retains the native model throughout the call.
        let result = unsafe { axo_coreml_description(self.handle.as_ptr(), &mut error) };
        native_json(result, error)
    }

    pub fn predict(&mut self, inputs: &Value, outputs: Option<&[String]>) -> Result<Value, String> {
        if !inputs.is_object() {
            return Err("Core ML inputs must be an object keyed by feature name".to_owned());
        }
        // A bounded writer avoids first allocating an unbounded JSON request.
        struct BoundedJSON(Vec<u8>);
        impl std::io::Write for BoundedJSON {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if bytes.len() > MAX_REQUEST_BYTES.saturating_sub(self.0.len()) {
                    return Err(std::io::Error::other("Core ML input JSON exceeds 24 MiB"));
                }
                self.0.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut json = BoundedJSON(Vec::new());
        let mut request = serde_json::json!({"features": inputs});
        if let Some(outputs) = outputs {
            request["outputs"] = serde_json::json!(outputs);
        }
        serde_json::to_writer(&mut json, &request).map_err(|error| error.to_string())?;
        let mut error = ptr::null_mut();
        // SAFETY: model and bytes are live for the call. The explicit length
        // means no terminating NUL is required; the bridge does not retain bytes.
        let result = unsafe {
            axo_coreml_predict(
                self.handle.as_ptr(),
                json.0.as_ptr().cast(),
                json.0.len(),
                &mut error,
            )
        };
        native_json(result, error)
    }
}

impl Drop for Model {
    fn drop(&mut self) {
        // SAFETY: the handle was retained by load and is released exactly once.
        unsafe { axo_coreml_free(self.handle.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Encode the tiny fixture directly from Apple's Model.proto,
    // FeatureTypes.proto, and GLMRegressor.proto (coremltools/mlmodel/format).
    // y = 2*x[0] + 3*x[1] + 1. No Python, code generation, or model download.
    fn varint(mut value: u64) -> Vec<u8> {
        let mut out = Vec::new();
        while value >= 128 {
            out.push((value as u8 & 127) | 128);
            value >>= 7;
        }
        out.push(value as u8);
        out
    }
    fn message(field: u64, data: &[u8]) -> Vec<u8> {
        [
            varint(field << 3 | 2),
            varint(data.len() as u64),
            data.to_vec(),
        ]
        .concat()
    }
    fn integer(field: u64, value: u64) -> Vec<u8> {
        [varint(field << 3), varint(value)].concat()
    }
    fn feature(name: &str, feature_type: &[u8]) -> Vec<u8> {
        [message(1, name.as_bytes()), message(3, feature_type)].concat()
    }
    fn glm_fixture() -> Vec<u8> {
        let array_type = [integer(1, 2), integer(2, 65568)].concat();
        let description = [
            message(1, &feature("x", &message(5, &array_type))),
            message(10, &feature("y", &message(2, &[]))),
            message(11, b"y"),
        ]
        .concat();
        let weights = [2.0f64.to_le_bytes(), 3.0f64.to_le_bytes()].concat();
        let glm = [
            message(1, &message(1, &weights)),
            message(2, &1.0f64.to_le_bytes()),
        ]
        .concat();
        [integer(1, 1), message(2, &description), message(300, &glm)].concat()
    }
    fn named_type(name: &str, value_type: &[u8]) -> Vec<u8> {
        [message(1, name.as_bytes()), message(2, value_type)].concat()
    }
    fn mlprogram_fixture() -> Vec<u8> {
        let scalar_type = message(1, &integer(1, 11)); // ValueType.tensorType, FLOAT32.
        let tensor_type = message(
            1,
            &[
                integer(1, 11),
                integer(2, 1),
                message(3, &message(1, &integer(1, 2))),
            ]
            .concat(),
        );
        let value = [
            message(2, &scalar_type),
            message(
                3,
                &message(1, &message(1, &message(1, &2.0f32.to_le_bytes()))),
            ),
        ]
        .concat();
        let constant = [
            message(1, b"const"),
            message(3, &named_type("two", &scalar_type)),
            message(5, &[message(1, b"val"), message(2, &value)].concat()),
        ]
        .concat();
        let argument = |name: &str, binding: &str| {
            message(
                2,
                &[
                    message(1, name.as_bytes()),
                    message(2, &message(1, &message(1, binding.as_bytes()))),
                ]
                .concat(),
            )
        };
        let multiply = [
            message(1, b"mul"),
            argument("x", "x"),
            argument("y", "two"),
            message(3, &named_type("y", &tensor_type)),
        ]
        .concat();
        let block = [
            message(2, b"y"),
            message(3, &constant),
            message(3, &multiply),
        ]
        .concat();
        let function = [
            message(1, &named_type("x", &tensor_type)),
            message(2, b"CoreML5"),
            message(3, &[message(1, b"CoreML5"), message(2, &block)].concat()),
        ]
        .concat();
        let program = [
            integer(1, 1),
            message(2, &[message(1, b"main"), message(2, &function)].concat()),
        ]
        .concat();
        let array_type = [integer(1, 2), integer(2, 65568)].concat();
        let feature_type = message(5, &array_type);
        let description = [
            message(1, &feature("x", &feature_type)),
            message(10, &feature("y", &feature_type)),
        ]
        .concat();
        [
            integer(1, 6),
            message(2, &description),
            message(502, &program),
        ]
        .concat()
    }
    fn program_with_operation(operation: &[u8]) -> Vec<u8> {
        let block = message(3, operation);
        let function = message(3, &[message(1, b"CoreML5"), message(2, &block)].concat());
        let program = [
            integer(1, 1),
            message(2, &[message(1, b"main"), message(2, &function)].concat()),
        ]
        .concat();
        [integer(1, 6), message(502, &program)].concat()
    }

    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new(bytes: &[u8]) -> Self {
            let unique = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos();
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let dir = std::env::temp_dir().join(format!(
                "axo-coreml-{}-{unique}-{sequence}",
                std::process::id()
            ));
            std::fs::create_dir(&dir).expect("fixture directory");
            let path = dir.join("glm.mlmodel");
            std::fs::write(&path, bytes).expect("fixture write");
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            if let Some(dir) = self.0.parent() {
                let _ = std::fs::remove_dir_all(dir);
            }
        }
    }
    #[test]
    fn native_glm_description_prediction_and_validation() {
        let fixture = Fixture::new(&glm_fixture());
        let mut model = Model::load(&fixture.0, &fixture.0.with_extension("work"))
            .expect("native GLM compile/load");
        let description = model.description().expect("native description");
        assert_eq!(description["inputs"]["x"]["shape"], json!([2]));
        assert_eq!(description["inputs"]["x"]["dtype"], "float32");
        assert_eq!(description["outputs"]["y"]["type"], "float");
        let input = json!({"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[4,5]}});
        let output = model.predict(&input, None).expect("native prediction");
        assert_eq!(output["y"]["value"], 24.0);
        assert!(model.predict(&json!({"wrong": input["x"]}), None).is_err());
        assert!(
            model
                .predict(
                    &json!({"x":{"type":"tensor","dtype":"float32","shape":[1],"data":[4]}}),
                    None
                )
                .is_err()
        );
        assert!(
            model
                .predict(
                    &json!({"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[null,5]}}),
                    None
                )
                .is_err()
        );
        assert!(
            model
                .predict(
                    &json!({"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[1e100,5]}}),
                    None
                )
                .is_err()
        );
        // Exercise nonfinite JSON at the FFI boundary itself: serde_json::Value
        // cannot represent NaN/Infinity. Neither token may reach Core ML.
        for input in [
            b"{\"x\":NaN}".as_slice(),
            b"{\"x\":1e999}",
            b"{\"x\":Infinity}",
        ] {
            let mut error = ptr::null_mut();
            let result = unsafe {
                axo_coreml_predict(
                    model.handle.as_ptr(),
                    input.as_ptr().cast(),
                    input.len(),
                    &mut error,
                )
            };
            assert!(native_json(result, error).is_err());
        }
    }
    #[test]
    fn rejects_plugin_operations_state_control_flow_and_blob_escapes_before_compilation() {
        for operation in ["custom.example", "load_file", "read_state", "while_loop"] {
            let fixture = Fixture::new(&program_with_operation(&message(1, operation.as_bytes())));
            assert!(
                Model::load(&fixture.0, &fixture.0.with_extension("work"))
                    .err()
                    .unwrap()
                    .contains("unsupported ML Program operation")
            );
        }
        let nested = [message(1, b"const"), message(4, &[])].concat();
        let fixture = Fixture::new(&program_with_operation(&nested));
        assert!(
            Model::load(&fixture.0, &fixture.0.with_extension("work"))
                .err()
                .unwrap()
                .contains("control-flow")
        );
        for path in [
            "/etc/passwd",
            "https://example.com/weights.bin",
            "@model_path/../../escape.bin",
            "@model_path/%2e%2e/escape.bin",
            "@model_path/missing.bin",
        ] {
            let value = message(5, &message(1, path.as_bytes()));
            let operation = [
                message(1, b"const"),
                message(5, &[message(1, b"val"), message(2, &value)].concat()),
            ]
            .concat();
            let fixture = Fixture::new(&program_with_operation(&operation));
            let error = Model::load(&fixture.0, &fixture.0.with_extension("work"))
                .err()
                .unwrap();
            assert!(error.contains("blob"), "{path}: {error}");
        }
        let state = message(2, &message(5, &[]));
        let operation = [
            message(1, b"const"),
            message(5, &[message(1, b"val"), message(2, &state)].concat()),
        ]
        .concat();
        let fixture = Fixture::new(&program_with_operation(&operation));
        assert!(
            Model::load(&fixture.0, &fixture.0.with_extension("work"))
                .err()
                .unwrap()
                .contains("stateful")
        );
    }

    #[test]
    fn rejects_nested_custom_models_layers_and_unbounded_specifications() {
        for model_type in [555, 556, 3000] {
            let linked = message(model_type, &[]);
            let fixture = Fixture::new(&message(202, &message(1, &linked)));
            assert!(
                Model::load(&fixture.0, &fixture.0.with_extension("work"))
                    .err()
                    .unwrap()
                    .contains("custom, linked")
            );
        }
        for layer_type in [500, 605, 615] {
            let fixture = Fixture::new(&message(500, &message(1, &message(layer_type, &[]))));
            assert!(
                Model::load(&fixture.0, &fixture.0.with_extension("work"))
                    .err()
                    .unwrap()
                    .contains("neural layers")
            );
        }
        let mut nested = glm_fixture();
        for _ in 0..40 {
            nested = message(202, &message(1, &nested));
        }
        let fixture = Fixture::new(&nested);
        assert!(
            Model::load(&fixture.0, &fixture.0.with_extension("work"))
                .err()
                .unwrap()
                .contains("nesting")
        );
        let overflow = Fixture::new(&[255; 12]);
        assert!(
            Model::load(&overflow.0, &overflow.0.with_extension("work"))
                .err()
                .unwrap()
                .contains("overflow")
        );
        let enormous_type = message(
            1,
            &[
                integer(1, 11),
                integer(2, 1),
                message(3, &message(1, &integer(1, 67108865))),
            ]
            .concat(),
        );
        let operation = [
            message(1, b"const"),
            message(3, &named_type("large", &enormous_type)),
        ]
        .concat();
        let oversized = Fixture::new(&program_with_operation(&operation));
        assert!(
            Model::load(&oversized.0, &oversized.0.with_extension("work"))
                .err()
                .unwrap()
                .contains("64 million")
        );
    }

    #[test]
    fn actual_system_device_probe() {
        let capability = probe().expect("native framework/device probe");
        assert_eq!(capability["available"], true);
        assert!(
            capability["devices"]
                .as_array()
                .unwrap()
                .iter()
                .any(|device| device["kind"] == "cpu")
        );
        assert_eq!(capability["compute_policy"], "all");
    }

    #[test]
    fn native_mlprogram_compiles_and_predicts_without_conversion_tools() {
        let fixture = Fixture::new(&mlprogram_fixture());
        let mut model = Model::load(&fixture.0, &fixture.0.with_extension("work"))
            .expect("native built-in ML Program compile/load");
        let output = model
            .predict(
                &json!({"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[4,5]}}),
                None,
            )
            .unwrap();
        assert_eq!(output["y"]["dtype"], "float32");
        assert_eq!(output["y"]["data"][0].as_f64(), Some(8.0));
        assert_eq!(output["y"]["data"][1].as_f64(), Some(10.0));
        assert!(
            model
                .predict(
                    &json!({"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[4,5]}}),
                    Some(&["missing".into()])
                )
                .unwrap_err()
                .contains("unknown selected output")
        );
        assert!(
            model
                .predict(
                    &json!({"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[4,5]}}),
                    Some(&["y".into(), "y".into()])
                )
                .unwrap_err()
                .contains("duplicate")
        );
    }

    #[test]
    #[ignore = "requires a checksum-verified public Core ML package"]
    fn real_mlprogram_package_loads_and_predicts_verified_image() {
        let path = std::env::var("AXO_TEST_COREML_MODEL").expect("set AXO_TEST_COREML_MODEL");
        let mut model = Model::load(Path::new(&path), &Path::new(&path).with_extension("work"))
            .expect("native public ML Program load");
        let description = model.description().unwrap();
        println!("{}", description);
        assert!(
            description["inputs"]
                .as_object()
                .is_some_and(|inputs| !inputs.is_empty())
        );
        assert!(
            description["outputs"]
                .as_object()
                .is_some_and(|outputs| !outputs.is_empty())
        );
        let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let output = model
            .predict(&json!({"image":{"type":"image","data_url":image}}), None)
            .expect("native image prediction");
        let probabilities = output["classLabel_probs"]["values"]
            .as_object()
            .expect("native probability dictionary");
        // This pinned model has 1000 logits but repeats the label "crane";
        // Core ML's native string-key dictionary therefore has 999 entries.
        assert_eq!(probabilities.len(), 999);
        let sum: f64 = probabilities
            .values()
            .map(|v| v.as_f64().expect("numeric probability"))
            .sum();
        assert!((sum - 1.0).abs() < 0.01);
        let label = output["classLabel"]["value"].as_str().unwrap();
        assert!(probabilities.contains_key(label));
        let selected = model
            .predict(
                &json!({"image":{"type":"image","data_url":image}}),
                Some(&["classLabel".into()]),
            )
            .unwrap();
        assert_eq!(selected.as_object().unwrap().len(), 1);
        assert_eq!(selected["classLabel"], output["classLabel"]);
        assert!(serde_json::to_vec(&selected).unwrap().len() < 1024);
        println!(
            "native FastViT prediction: label={label:?}, classes={}, sum={sum}, JSON bytes={}",
            probabilities.len(),
            serde_json::to_vec(&output).unwrap().len()
        );
        assert!(model.predict(&json!({"image":{"type":"image","data_url":image.replacen("image/png", "image/jpeg", 1)}}), None).unwrap_err().contains("MIME"));
        assert!(
            model
                .predict(
                    &json!({"image":{"type":"image","data_url":"data:image/png;base64,!!!!"}}),
                    None
                )
                .is_err()
        );
        assert!(
            model
                .predict(
                    &json!({"image":{"type":"image","data_url":"file:///etc/passwd"}}),
                    None
                )
                .is_err()
        );
    }

    #[test]
    fn rejects_custom_model_before_loading() {
        let bytes = [integer(1, 3), message(555, &message(1, b"UntrustedClass"))].concat();
        let fixture = Fixture::new(&bytes);
        assert!(
            Model::load(&fixture.0, &fixture.0.with_extension("work"))
                .err()
                .expect("custom model rejected")
                .contains("custom")
        );
    }
}

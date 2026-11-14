//! Parse raw feature bindings once; retain numeric, shape, name and output-selection guarantees.
use crate::{api::Image, service::Error};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

const ELEMENTS: usize = 4096;
const JS_INTEGER: f64 = 9007199254740991.0;
#[derive(Debug)]
enum Tensor {
    Float32 { shape: Vec<usize>, data: Vec<f32> },
    Int32 { shape: Vec<usize>, data: Vec<i32> },
}
#[derive(Debug)]
enum Feature {
    Int(i64),
    Float(f64),
    Text(String),
    Tensor(Tensor),
    Image(Image),
}
#[derive(Debug)]
pub struct Prediction {
    features: BTreeMap<String, Feature>,
    outputs: Option<Vec<String>>,
}
fn object<'a>(value: &'a Value, allowed: &[&str]) -> Result<&'a Map<String, Value>, Error> {
    let object = value
        .as_object()
        .ok_or_else(|| Error::invalid("prediction features must be objects"))?;
    if object.keys().any(|name| !allowed.contains(&name.as_str())) {
        return Err(Error::invalid("unknown prediction field"));
    }
    Ok(object)
}
fn name(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && !value.contains('\0')
}
fn number(value: &Value) -> Result<f64, Error> {
    value
        .as_f64()
        .filter(|n| n.is_finite())
        .ok_or_else(|| Error::invalid("prediction numbers must be finite"))
}
fn integer(value: &Value, lower: f64, upper: f64) -> Result<i64, Error> {
    let value = number(value)?;
    if value.fract() != 0.0 || value < lower || value > upper {
        return Err(Error::invalid(
            "prediction integer is outside its exact range",
        ));
    }
    Ok(value as i64)
}
impl Prediction {
    pub fn parse(value: &Value) -> Result<Self, Error> {
        let input = object(value, &["features", "outputs"])?;
        let bindings = input
            .get("features")
            .and_then(Value::as_object)
            .ok_or_else(|| Error::invalid("predict input requires {features, outputs?}"))?;
        if bindings.len() > 32 || bindings.keys().any(|key| !name(key)) {
            return Err(Error::invalid(
                "prediction requires at most 32 named features (1..128 UTF-8 bytes)",
            ));
        }
        let mut features = BTreeMap::new();
        let mut elements = 0usize;
        let mut text_bytes = 0usize;
        for (name, value) in bindings {
            let tag = value
                .get("type")
                .and_then(Value::as_str)
                .ok_or_else(|| Error::invalid("prediction feature needs a type tag"))?;
            let feature = match tag {
                "int" | "float" | "string" => {
                    let scalar = object(value, &["type", "value"])?;
                    let value = scalar
                        .get("value")
                        .ok_or_else(|| Error::invalid("missing scalar value"))?;
                    elements += 1;
                    match tag {
                        "int" => Feature::Int(integer(value, -JS_INTEGER, JS_INTEGER)?),
                        "float" => Feature::Float(number(value)?),
                        _ => {
                            let text = value
                                .as_str()
                                .ok_or_else(|| Error::invalid("expected prediction string"))?;
                            text_bytes = text_bytes.saturating_add(text.len());
                            if text_bytes > 32768 {
                                return Err(Error::invalid(
                                    "prediction strings exceed 32768 total UTF-8 bytes",
                                ));
                            }
                            Feature::Text(text.to_owned())
                        }
                    }
                }
                "tensor" => {
                    let tensor = object(value, &["type", "dtype", "shape", "data"])?;
                    let raw_shape = tensor
                        .get("shape")
                        .and_then(Value::as_array)
                        .ok_or_else(|| Error::invalid("tensor needs a shape array"))?;
                    if raw_shape.is_empty() || raw_shape.len() > 16 {
                        return Err(Error::invalid("tensor rank must be 1..16"));
                    }
                    let shape: Vec<usize> = raw_shape
                        .iter()
                        .map(|v| integer(v, 1.0, ELEMENTS as f64).map(|n| n as usize))
                        .collect::<Result<_, _>>()?;
                    let count = shape
                        .iter()
                        .try_fold(1usize, |total, size| {
                            total.checked_mul(*size).filter(|n| *n <= ELEMENTS)
                        })
                        .ok_or_else(|| Error::invalid("tensor shape exceeds 4096 elements"))?;
                    let data = tensor
                        .get("data")
                        .and_then(Value::as_array)
                        .ok_or_else(|| Error::invalid("tensor needs numeric data"))?;
                    if data.len() != count {
                        return Err(Error::invalid("tensor data length differs from shape"));
                    }
                    elements += count;
                    if elements > ELEMENTS {
                        return Err(Error::invalid("prediction exceeds 4096 input elements"));
                    }
                    Feature::Tensor(match tensor.get("dtype").and_then(Value::as_str) {
                        Some("float32") => Tensor::Float32 {
                            shape,
                            data: data
                                .iter()
                                .map(|v| {
                                    let value = number(v)? as f32;
                                    if !value.is_finite() {
                                        return Err(Error::invalid(
                                            "tensor value exceeds float32 range",
                                        ));
                                    }
                                    Ok(value)
                                })
                                .collect::<Result<_, _>>()?,
                        },
                        Some("int32") => Tensor::Int32 {
                            shape,
                            data: data
                                .iter()
                                .map(|v| {
                                    integer(v, i32::MIN as f64, i32::MAX as f64).map(|n| n as i32)
                                })
                                .collect::<Result<_, _>>()?,
                        },
                        _ => {
                            return Err(Error::invalid(
                                "prediction tensor dtype must be float32 or int32",
                            ));
                        }
                    })
                }
                "image" => {
                    let image = object(value, &["type", "image"])?;
                    elements += 1;
                    Feature::Image(
                        serde_json::from_value(image.get("image").cloned().ok_or_else(|| {
                            Error::invalid("image feature needs an image attachment or data URL")
                        })?)
                        .map_err(|_| Error::invalid("invalid prediction image"))?,
                    )
                }
                _ => return Err(Error::invalid("unsupported prediction input feature type")),
            };
            if elements > ELEMENTS {
                return Err(Error::invalid("prediction exceeds 4096 input elements"));
            }
            features.insert(name.clone(), feature);
        }
        let outputs = match input.get("outputs") {
            None => None,
            Some(value) => {
                let values = value.as_array().ok_or_else(|| {
                    Error::invalid("selected outputs must be an array of feature names")
                })?;
                if values.is_empty() || values.len() > 32 {
                    return Err(Error::invalid("select 1..32 output features"));
                }
                let mut unique = BTreeSet::new();
                let names = values
                    .iter()
                    .map(|v| {
                        let value = v
                            .as_str()
                            .filter(|v| name(v))
                            .ok_or_else(|| Error::invalid("invalid selected output name"))?;
                        if !unique.insert(value) {
                            return Err(Error::invalid("duplicate selected output name"));
                        }
                        Ok(value.to_owned())
                    })
                    .collect::<Result<_, _>>()?;
                Some(names)
            }
        };
        Ok(Self { features, outputs })
    }
    pub fn images(&self) -> impl Iterator<Item = &Image> {
        self.features.values().filter_map(|feature| match feature {
            Feature::Image(image) => Some(image),
            _ => None,
        })
    }
    pub fn images_mut(&mut self) -> impl Iterator<Item = &mut Image> {
        self.features
            .values_mut()
            .filter_map(|feature| match feature {
                Feature::Image(image) => Some(image),
                _ => None,
            })
    }
    pub(crate) fn validate_outputs(&self, value: Value) -> Result<Value, Error> {
        let bindings = value
            .as_object()
            .filter(|bindings| bindings.len() <= 32)
            .ok_or_else(|| {
                Error::failed(
                    "native prediction returned too many or invalid features; select output names",
                )
            })?;
        if let Some(selected) = &self.outputs {
            if bindings.len() != selected.len()
                || selected.iter().any(|name| !bindings.contains_key(name))
            {
                return Err(Error::failed(
                    "native prediction did not match selected outputs",
                ));
            }
        }
        let mut ordinary = Map::new();
        let mut dictionary_elements = 0usize;
        for (key, value) in bindings {
            if !name(key) {
                return Err(Error::failed("invalid native output feature name"));
            }
            if value["type"] == "dictionary" {
                let dictionary = object(value, &["type", "values"])?;
                let values = dictionary
                    .get("values")
                    .and_then(Value::as_object)
                    .ok_or_else(|| Error::failed("invalid native output dictionary"))?;
                dictionary_elements = dictionary_elements.saturating_add(values.len());
                if dictionary_elements > ELEMENTS {
                    return Err(Error::failed("prediction output exceeds 4096 elements"));
                }
                for (label, value) in values {
                    if label.len() > 4096 {
                        return Err(Error::failed(
                            "native dictionary label exceeds 4096 UTF-8 bytes",
                        ));
                    }
                    number(value)?;
                }
            } else {
                ordinary.insert(key.clone(), value.clone());
            }
        }
        let parsed = Self::parse(&json!({"features": ordinary}))?;
        let elements: usize = parsed
            .features
            .values()
            .map(|feature| match feature {
                Feature::Tensor(Tensor::Float32 { data, .. }) => data.len(),
                Feature::Tensor(Tensor::Int32 { data, .. }) => data.len(),
                _ => 1,
            })
            .sum();
        if elements + dictionary_elements > ELEMENTS || parsed.images().next().is_some() {
            return Err(Error::failed(
                "invalid or oversized native prediction outputs",
            ));
        }
        Ok(value)
    }
    pub(crate) fn native_request(&self) -> Result<Value, Error> {
        let mut features = Map::new();
        for (name, feature) in &self.features {
            let value = match feature {
                Feature::Int(value) => json!({"type":"int","value":value}),
                Feature::Float(value) => json!({"type":"float","value":value}),
                Feature::Text(value) => json!({"type":"string","value":value}),
                Feature::Tensor(Tensor::Float32 { shape, data }) => {
                    json!({"type":"tensor","dtype":"float32","shape":shape,"data":data})
                }
                Feature::Tensor(Tensor::Int32 { shape, data }) => {
                    json!({"type":"tensor","dtype":"int32","shape":shape,"data":data})
                }
                Feature::Image(Image::Data(url)) => json!({"type":"image","data_url":url}),
                Feature::Image(Image::Asset(_)) => {
                    return Err(Error::invalid(
                        "prediction image assets must be resolved before inference",
                    ));
                }
            };
            features.insert(name.clone(), value);
        }
        let mut request = json!({"op":"predict","features":features});
        if let Some(outputs) = &self.outputs {
            request["outputs"] = json!(outputs);
        }
        Ok(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_exact_values_and_selected_outputs_into_native_data_only() {
        let prediction = Prediction::parse(&json!({"features":{"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[4,5]},"tag":{"type":"string","value":"test"}},"outputs":["y"]})).unwrap();
        let native = prediction.native_request().unwrap();
        assert_eq!(native["op"], "predict");
        assert_eq!(native["outputs"], json!(["y"]));
        assert_eq!(native["features"]["x"]["data"], json!([4.0, 5.0]));
        assert_eq!(prediction.images().count(), 0);
        assert!(Prediction::parse(&json!({"features":{}})).is_ok());
    }
    #[test]
    fn rejects_ambiguous_shapes_overflow_unknown_fields_and_output_aliases() {
        for input in [
            json!({"features":{"x":{"type":"tensor","dtype":"float32","shape":[2],"data":[1]}}}),
            json!({"features":{"x":{"type":"tensor","dtype":"float32","shape":[4096,4096],"data":[]}}}),
            json!({"features":{"x":{"type":"tensor","dtype":"float32","shape":[1],"data":[1e100]}}}),
            json!({"features":{"x":{"type":"tensor","dtype":"int32","shape":[1],"data":[1.5]}}}),
            json!({"features":{"x":{"type":"int","value":9007199254740992u64}}}),
            json!({"features":{"x":{"type":"int","value":true}}}),
            json!({"features":{"x":{"type":"float","value":1,"ignored":"no"}}}),
            json!({"features":{},"outputs":["a","a"]}),
            json!({"features":{},"outputs":[]}),
            json!({"features":{},"unknown":true}),
        ] {
            assert!(Prediction::parse(&input).is_err(), "{input}");
        }
        let input = json!({"features":{"x":{"type":"image","image":"data:image/png;base64,AA=="}},"outputs":["label"]});
        let mut parsed = Prediction::parse(&input).unwrap();
        assert_eq!(parsed.images().count(), 1);
        assert_eq!(parsed.images_mut().count(), 1);
        assert_eq!(
            parsed.native_request().unwrap()["features"]["x"]["data_url"],
            "data:image/png;base64,AA=="
        );
    }
}

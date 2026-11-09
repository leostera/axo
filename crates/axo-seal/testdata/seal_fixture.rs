//! Test-only cross-language sealer. Never packaged with Axo.
use std::io::Read;
fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let request: serde_json::Value = serde_json::from_str(&input).unwrap();
    let aad = axo_seal::aad(request["id"].as_str().unwrap(), request["origin"].as_str());
    let (enc, ciphertext) = axo_seal::seal(
        request["key"].as_str().unwrap(),
        request["values"].to_string().as_bytes(),
        &aad,
    )
    .unwrap();
    println!("{}", serde_json::json!({"enc":enc,"ciphertext":ciphertext}));
}

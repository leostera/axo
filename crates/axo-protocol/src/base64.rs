//! Base64 (RFC 4648, standard alphabet, padded) for terminal bytes on the wire, without a
//! dependency: terminal output events carry it, terminal input arrives in it.

use std::io;

/// The longest encoded terminal input Axod accepts in one request (48 KiB of bytes).
pub const MAX_TERMINAL_INPUT_BASE64_BYTES: usize = 65_536;

/// Decodes one terminal input request: non-empty, at most `MAX_TERMINAL_INPUT_BASE64_BYTES`,
/// padded, and canonical (padding bits zero), so every input has exactly one encoding.
pub fn decode_terminal_input(input: &str) -> io::Result<Vec<u8>> {
    if input.len() > MAX_TERMINAL_INPUT_BASE64_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "terminal input is not bounded, padded base64",
        ));
    }
    decode(input)
}

/// Decodes non-empty, padded, canonical base64 (padding bits zero), so every value has exactly
/// one encoding.
pub fn decode(input: &str) -> io::Result<Vec<u8>> {
    let (chunks, trailing_bytes) = input.as_bytes().as_chunks::<4>();
    if input.is_empty() || !trailing_bytes.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "terminal input is not bounded, padded base64",
        ));
    }
    let mut decoded = Vec::with_capacity(input.len() / 4 * 3);
    let chunk_count = chunks.len();
    for (index, chunk) in chunks.iter().enumerate() {
        let a = base64_value(chunk[0])?;
        let b = base64_value(chunk[1])?;
        let last = index + 1 == chunk_count;
        let c = if chunk[2] == b'=' && last {
            None
        } else {
            Some(base64_value(chunk[2])?)
        };
        let d = if chunk[3] == b'=' && last {
            None
        } else {
            Some(base64_value(chunk[3])?)
        };
        if c.is_none() && d.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid base64 padding",
            ));
        }
        if (c.is_none() && b & 0x0f != 0)
            || (d.is_none() && c.is_some_and(|value| value & 0x03 != 0))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "non-canonical base64 padding bits",
            ));
        }
        let value = ((a as u32) << 18)
            | ((b as u32) << 12)
            | ((c.unwrap_or(0) as u32) << 6)
            | d.unwrap_or(0) as u32;
        decoded.push((value >> 16) as u8);
        if c.is_some() {
            decoded.push((value >> 8) as u8);
        }
        if d.is_some() {
            decoded.push(value as u8);
        }
    }
    Ok(decoded)
}

fn base64_value(byte: u8) -> io::Result<u8> {
    match byte {
        b'A'..=b'Z' => Ok(byte - b'A'),
        b'a'..=b'z' => Ok(byte - b'a' + 26),
        b'0'..=b'9' => Ok(byte - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid base64 input",
        )),
    }
}

pub fn encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let a = chunk[0] as u32;
        let b = chunk.get(1).copied().unwrap_or(0) as u32;
        let c = chunk.get(2).copied().unwrap_or(0) as u32;
        let value = (a << 16) | (b << 8) | c;
        encoded.push(TABLE[((value >> 18) & 63) as usize] as char);
        encoded.push(TABLE[((value >> 12) & 63) as usize] as char);
        encoded.push(if chunk.len() > 1 {
            TABLE[((value >> 6) & 63) as usize] as char
        } else {
            '='
        });
        encoded.push(if chunk.len() > 2 {
            TABLE[(value & 63) as usize] as char
        } else {
            '='
        });
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    const RFC_4648_VECTORS: [(&str, &str); 6] = [
        ("f", "Zg=="),
        ("fo", "Zm8="),
        ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy"),
    ];

    #[test]
    fn encodes_and_decodes_the_rfc_4648_vectors() {
        assert_eq!(encode(b""), "");
        for (plain, encoded) in RFC_4648_VECTORS {
            assert_eq!(encode(plain.as_bytes()), encoded);
            assert_eq!(decode_terminal_input(encoded).unwrap(), plain.as_bytes());
        }
    }

    #[test]
    fn every_byte_value_and_length_round_trips() {
        let all: Vec<u8> = (0..=255).collect();
        for length in 1..=all.len() {
            let bytes = &all[..length];
            assert_eq!(
                decode_terminal_input(&encode(bytes)).unwrap(),
                bytes,
                "length {length}"
            );
        }
    }

    #[test]
    fn rejects_input_that_is_empty_unpadded_or_outside_the_alphabet() {
        for input in [
            "", "Zg", "Zm9", "Zm9v!", "Zm9-", "Zm9_", "Zg==Zg==", "Zm=v", "Z===", "====",
        ] {
            let error = decode_terminal_input(input).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput, "{input:?}");
        }
    }

    #[test]
    fn rejects_non_canonical_padding_bits() {
        // "Zh==" and "Zm9=" decode to the same bytes as "Zg==" and "Zm8=" if the spare bits are
        // ignored; only the canonical spelling is accepted.
        for input in ["Zh==", "Zm9="] {
            assert_eq!(
                decode_terminal_input(input).unwrap_err().kind(),
                io::ErrorKind::InvalidInput,
                "{input:?}"
            );
        }
    }

    #[test]
    fn terminal_input_is_bounded_at_exactly_the_limit() {
        let at_limit = "A".repeat(MAX_TERMINAL_INPUT_BASE64_BYTES);
        assert_eq!(
            decode_terminal_input(&at_limit).unwrap().len(),
            MAX_TERMINAL_INPUT_BASE64_BYTES / 4 * 3
        );
        let over = "A".repeat(MAX_TERMINAL_INPUT_BASE64_BYTES + 4);
        assert_eq!(
            decode_terminal_input(&over).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }
}

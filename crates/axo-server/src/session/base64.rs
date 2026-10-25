//! Base64 for terminal bytes on the wire, without a dependency.

use std::io;

pub(super) fn decode_base64(input: &str) -> io::Result<Vec<u8>> {
    let (chunks, trailing_bytes) = input.as_bytes().as_chunks::<4>();
    if input.is_empty() || input.len() > 65_536 || !trailing_bytes.is_empty() {
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

pub(super) fn encode_base64(input: &[u8]) -> String {
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

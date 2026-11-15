//! Secure storage for the optional Hugging Face access token.
//!
//! The token used to live in the webview's `localStorage`, i.e. plaintext on
//! disk. It now goes through DPAPI on Windows (per-user encryption bound to the
//! login) and a 0600 file elsewhere, and never leaves the main process.

use std::fs;
use std::path::PathBuf;

use crate::paths::local_metadata_dir;

fn token_path() -> PathBuf {
    local_metadata_dir().join("hf_token.bin")
}

/// Stores the token. An empty string clears it.
pub fn save_hf_token(token: &str) -> Result<(), String> {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return clear_hf_token();
    }
    let dir = local_metadata_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("Failed to create metadata dir: {}", e))?;

    let protected = protect(trimmed.as_bytes())?;
    fs::write(token_path(), protected).map_err(|e| format!("Failed to write token: {}", e))?;
    restrict_permissions(&token_path());
    Ok(())
}

/// Reads the token, or `None` when nothing is stored.
pub fn load_hf_token() -> Option<String> {
    let raw = fs::read(token_path()).ok()?;
    if raw.is_empty() {
        return None;
    }
    let plain = unprotect(&raw).ok()?;
    let token = String::from_utf8(plain).ok()?;
    let token = token.trim().to_string();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

pub fn clear_hf_token() -> Result<(), String> {
    let path = token_path();
    if path.exists() {
        fs::remove_file(&path).map_err(|e| format!("Failed to delete token: {}", e))?;
    }
    Ok(())
}

/// True when a token is present — the UI shows "connected" without the value.
pub fn has_hf_token() -> bool {
    token_path().exists()
}

#[cfg(windows)]
fn protect(plain: &[u8]) -> Result<Vec<u8>, String> {
    // windows-sys 0.61 exposes the wincrypt typedef under its C name.
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB as DATA_BLOB,
    };
    unsafe {
        let input = DATA_BLOB {
            cbData: plain.len() as u32,
            pbData: plain.as_ptr() as *mut u8,
        };
        let mut output = DATA_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        let ok = CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        );
        if ok == 0 {
            return Err("DPAPI encryption failed".to_string());
        }
        let slice = std::slice::from_raw_parts(output.pbData, output.cbData as usize);
        let bytes = slice.to_vec();
        LocalFree(output.pbData as _);
        Ok(bytes)
    }
}

#[cfg(windows)]
fn unprotect(protected: &[u8]) -> Result<Vec<u8>, String> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB as DATA_BLOB,
    };
    unsafe {
        let input = DATA_BLOB {
            cbData: protected.len() as u32,
            pbData: protected.as_ptr() as *mut u8,
        };
        let mut output = DATA_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        let ok = CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        );
        if ok == 0 {
            return Err("DPAPI decryption failed".to_string());
        }
        let slice = std::slice::from_raw_parts(output.pbData, output.cbData as usize);
        let bytes = slice.to_vec();
        LocalFree(output.pbData as _);
        Ok(bytes)
    }
}

#[cfg(not(windows))]
fn protect(plain: &[u8]) -> Result<Vec<u8>, String> {
    Ok(plain.to_vec())
}

#[cfg(not(windows))]
fn unprotect(protected: &[u8]) -> Result<Vec<u8>, String> {
    Ok(protected.to_vec())
}

#[cfg(unix)]
fn restrict_permissions(path: &PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &PathBuf) {
    // DPAPI already binds the ciphertext to the user account on Windows.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_roundtrip_is_reversible() {
        let plain = b"hf_test_token_value";
        let protected = protect(plain).expect("protect");
        let restored = unprotect(&protected).expect("unprotect");
        assert_eq!(restored, plain);
    }
}

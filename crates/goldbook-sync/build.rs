use std::{env, fs, path::Path};
fn main() {
    let root = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../addon/Goldbook");
    println!("cargo:rerun-if-changed={}", root.display());
    let mut files = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.is_file())
        .collect::<Vec<_>>();
    files.sort();
    let body = files
        .iter()
        .map(|p| {
            format!(
                "({:?}, include_bytes!({:?}).as_slice()),",
                p.file_name().unwrap().to_str().unwrap(),
                p.canonicalize().unwrap().to_str().unwrap()
            )
        })
        .collect::<String>();
    fs::write(
        Path::new(&env::var("OUT_DIR").unwrap()).join("addon.rs"),
        format!("pub const BUNDLED_ADDON: &[(&str, &[u8])] = &[{body}];"),
    )
    .unwrap();
}

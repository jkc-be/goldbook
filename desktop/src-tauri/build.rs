fn main() {
    let stamp = std::process::Command::new("git")
        .args(["show", "-s", "--format=%ct", "HEAD"])
        .output()
        .expect("git must be available when building Goldbook");
    assert!(stamp.status.success());
    println!(
        "cargo:rustc-env=GOLDBOOK_ADDON_SEQUENCE={}",
        String::from_utf8(stamp.stdout).unwrap().trim()
    );
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../.git/refs/heads/main");
    tauri_build::build();
}

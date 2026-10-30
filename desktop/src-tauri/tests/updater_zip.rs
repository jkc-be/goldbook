use std::{
    fs,
    io::{Cursor, Write},
};
use zip::{CompressionMethod, ZipArchive, ZipWriter, result::ZipError, write::SimpleFileOptions};

fn archive() -> Vec<u8> {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    writer
        .start_file(
            "safe.txt",
            SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
        )
        .unwrap();
    writer.write_all(b"update contents").unwrap();
    writer.finish().unwrap().into_inner()
}

#[test]
fn oversized_symlink_targets_are_rejected_before_filesystem_operations() {
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    writer
        .add_symlink("link", "a".repeat(4097), SimpleFileOptions::default())
        .unwrap();
    let bytes = writer.finish().unwrap().into_inner();
    let destination = tempfile::tempdir().unwrap();

    let result = ZipArchive::new(Cursor::new(bytes))
        .and_then(|mut archive| archive.extract(destination.path()));

    assert!(matches!(result, Err(ZipError::InvalidArchive(_))));
    assert!(fs::symlink_metadata(destination.path().join("link")).is_err());
}

#[test]
fn symlinks_cannot_escape_the_update_directory() {
    let root = tempfile::tempdir().unwrap();
    let existing = root.path().join("existing.txt");
    fs::write(&existing, b"existing contents").unwrap();
    let destination = root.path().join("update");
    fs::create_dir(&destination).unwrap();
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    writer
        .add_symlink("link", "../existing.txt", SimpleFileOptions::default())
        .unwrap();
    let bytes = writer.finish().unwrap().into_inner();

    let result =
        ZipArchive::new(Cursor::new(bytes)).and_then(|mut archive| archive.extract(&destination));

    assert!(matches!(result, Err(ZipError::InvalidArchive(_))));
    assert_eq!(fs::read(existing).unwrap(), b"existing contents");
    assert!(fs::symlink_metadata(destination.join("link")).is_err());
}

#[test]
fn ordinary_zip_updates_still_extract() {
    let destination = tempfile::tempdir().unwrap();
    ZipArchive::new(Cursor::new(archive()))
        .unwrap()
        .extract(destination.path())
        .unwrap();
    assert_eq!(
        fs::read(destination.path().join("safe.txt")).unwrap(),
        b"update contents"
    );
}

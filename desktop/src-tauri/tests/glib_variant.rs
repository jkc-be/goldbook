#[cfg(target_os = "linux")]
use gtk::glib;

#[cfg(target_os = "linux")]
#[test]
fn glib_string_iteration_reads_every_requested_element() {
    use glib::variant::ToVariant;

    let value = ["first", "middle", "last"].to_variant();
    assert_eq!(value.array_iter_str().unwrap().next(), Some("first"));
    assert_eq!(value.array_iter_str().unwrap().nth(1), Some("middle"));
    assert_eq!(value.array_iter_str().unwrap().last(), Some("last"));
    assert_eq!(value.array_iter_str().unwrap().next_back(), Some("last"));
    assert_eq!(value.array_iter_str().unwrap().nth_back(1), Some("middle"));
    assert_eq!(
        value.array_iter_str().unwrap().collect::<Vec<_>>(),
        ["first", "middle", "last"]
    );
    assert_eq!(
        value.array_iter_str().unwrap().rev().collect::<Vec<_>>(),
        ["last", "middle", "first"]
    );
    let empty: [&str; 0] = [];
    assert_eq!(empty.to_variant().array_iter_str().unwrap().next(), None);
}

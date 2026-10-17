#![cfg(target_os = "linux")]

use gtk::glib::{Object, PtrSlice, prelude::*};

#[test]
fn truncate_releases_removed_objects_and_allows_reuse() {
    let first = Object::new::<Object>();
    let second = Object::new::<Object>();
    let third = Object::new::<Object>();
    let first_weak = first.downgrade();
    let second_weak = second.downgrade();
    let third_weak = third.downgrade();
    let mut items = PtrSlice::from(vec![first, second, third]);
    let allocation = items.as_ptr();

    items.truncate(1);
    assert_eq!(items.len(), 1);
    assert_eq!(items.as_ptr(), allocation);
    assert_eq!(first_weak.upgrade().as_ref(), Some(&items[0]));
    assert!(second_weak.upgrade().is_none());
    assert!(third_weak.upgrade().is_none());
    unsafe {
        assert!((*items.as_ptr().add(1)).is_null());
    }

    let replacement = Object::new::<Object>();
    let replacement_weak = replacement.downgrade();
    items.push(replacement);
    assert_eq!(items.len(), 2);
    assert_eq!(items.as_ptr(), allocation);
    assert_eq!(replacement_weak.upgrade().as_ref(), Some(&items[1]));

    items.truncate(0);
    assert!(items.is_empty());
    assert!(first_weak.upgrade().is_none());
    assert!(replacement_weak.upgrade().is_none());

    let reused = Object::new::<Object>();
    let reused_weak = reused.downgrade();
    items.push(reused);
    assert_eq!(items.len(), 1);
    assert_eq!(items.as_ptr(), allocation);
    assert_eq!(reused_weak.upgrade().as_ref(), Some(&items[0]));
    drop(items);
    assert!(reused_weak.upgrade().is_none());
}

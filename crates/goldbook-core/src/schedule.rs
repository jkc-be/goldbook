/// Blizzard publishes the EU PvP houses' snapshots between :22 and :25 UTC.
pub const AUCTION_POLL_MINUTE: u64 = 30;
/// A poll takes seconds, but players' clocks can be minutes off the server's.
pub const AUCTION_STORED_MINUTE: u64 = AUCTION_POLL_MINUTE + 5;

/// The first Unix time after `now` that is `minute` minutes past a UTC hour.
pub fn next_minute_past_hour(now: u64, minute: u64) -> u64 {
    let this_hour = now - now % 3600 + minute % 60 * 60;
    if this_hour > now {
        this_hour
    } else {
        this_hour + 3600
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_next_time_is_strictly_after_now_and_crosses_midnight() {
        for (now, minute, next, case) in [
            (1793985867, 30, 1793986200, "17:24:27 -> 17:30:00"),
            (1793986200, 30, 1793989800, "17:30:00 -> 18:30:00"),
            (1793986201, 30, 1793989800, "17:30:01 -> 18:30:00"),
            (1794008700, 30, 1794011400, "23:45:00 -> 00:30:00 next day"),
            (1793986200, 35, 1793986500, "17:30:00 -> 17:35:00"),
            (1794009599, 0, 1794009600, "23:59:59 -> 00:00:00 next day"),
            (1793985000, 90, 1793986200, "17:10:00 -> 17:30:00"),
        ] {
            assert_eq!(next_minute_past_hour(now, minute), next, "{case}");
        }
    }
}

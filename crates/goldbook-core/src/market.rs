//! The addon's full-scan statistics (`Stats.MarketValue` and
//! `Stats.Summarize` in `addon/Goldbook/Stats.lua`), so that a scan the server
//! builds carries the numbers an in-game scan would.
//!
//! The arithmetic is in `f64`, as Lua's numbers are, so rounding matches too.

const ALWAYS_SHARE: f64 = 0.15;
const MAX_SHARE: f64 = 0.30;
const MAX_STEP: f64 = 1.2;
const OUTLIER_SIGMA: f64 = 1.5;

/// One auction: its price per unit and its units, in copper.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Listing {
    pub price: u64,
    pub count: u64,
}

/// One item's row in a full scan, the fields of a `PriceRow` after its key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Summary {
    pub min: u64,
    pub market_value: u64,
    pub quantity: u64,
    pub auctions: u64,
}

/// An item's auctions as a scan row, or None when they hold no units.
pub fn summarize(mut listings: Vec<Listing>) -> Option<Summary> {
    listings.sort_by_key(|listing| listing.price);
    let quantity = listings.iter().map(|listing| listing.count).sum();
    Some(Summary {
        min: listings.first()?.price,
        market_value: market_value(&listings, quantity)?,
        quantity,
        auctions: listings.len() as u64,
    })
}

/// The cheapest 15% of units always count, units up to 30% count until the
/// price steps up by more than 20%, and prices beyond 1.5 standard deviations
/// of that window are dropped. `sorted` is ordered by price.
fn market_value(sorted: &[Listing], total: u64) -> Option<u64> {
    if total == 0 {
        return None;
    }
    let total = total as f64;
    let always = (total * ALWAYS_SHARE).ceil().max(1.0);
    let limit = (total * MAX_SHARE).ceil().max(1.0);
    let mut window: Vec<(f64, f64)> = Vec::new();
    let (mut seen, mut previous) = (0.0, 0.0);
    for listing in sorted {
        let price = listing.price as f64;
        if seen >= limit || (seen >= always && price > previous * MAX_STEP) {
            break;
        }
        let take = (listing.count as f64).min(limit - seen);
        window.push((price, take));
        seen += take;
        previous = price;
    }

    let mean = window
        .iter()
        .fold(0.0, |sum, (price, count)| sum + price * count)
        / seen;
    let variance = window.iter().fold(0.0, |variance, (price, count)| {
        variance + (price - mean).powi(2) * count
    });
    let spread = (variance / seen).sqrt() * OUTLIER_SIGMA;

    let (mut kept_sum, mut kept) = (0.0, 0.0);
    for (price, count) in &window {
        if (price - mean).abs() <= spread {
            kept_sum += price * count;
            kept += count;
        }
    }
    Some((kept_sum / kept + 0.5).floor() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(listings: &[(u64, u64)]) -> Option<(u64, u64, u64, u64)> {
        let listings = listings
            .iter()
            .map(|&(price, count)| Listing { price, count })
            .collect();
        summarize(listings).map(|s| (s.min, s.market_value, s.quantity, s.auctions))
    }

    // Each expected row is what addon/Goldbook/Stats.lua's Summarize returns
    // for the same listings under LuaJIT.
    #[test]
    fn rows_match_the_addon() {
        for (name, listings, expected) in [
            ("single", vec![(7, 1)], (7, 7, 1, 1)),
            (
                "expensive tail",
                vec![(500, 70), (110, 10), (100, 10), (105, 10)],
                (100, 105, 100, 4),
            ),
            (
                "a step over 20 percent cuts the window",
                vec![(100, 2), (130, 8)],
                (100, 100, 10, 2),
            ),
            (
                "a step of 20 percent stays in the window",
                vec![(100, 2), (120, 8)],
                (100, 107, 10, 2),
            ),
            (
                "cheapest share across a step",
                vec![(100, 1), (300, 9)],
                (100, 233, 10, 2),
            ),
            (
                "low outlier",
                vec![(50, 1), (100, 5), (1000, 14)],
                (50, 100, 20, 3),
            ),
            (
                "ties",
                vec![(104, 1), (100, 1), (108, 2), (104, 2), (100, 1), (300, 13)],
                (100, 102, 20, 6),
            ),
            (
                "large counts",
                vec![
                    (27, 700_000),
                    (26, 600_000),
                    (25, 600_000),
                    (30, 2_000_000),
                    (4000, 10),
                ],
                (25, 25, 3_900_010, 5),
            ),
            (
                "high outlier in the window",
                vec![(100, 2), (102, 2), (103, 2), (119, 1), (400, 23)],
                (100, 102, 30, 5),
            ),
            (
                "window stops at 30 percent",
                vec![(100, 1), (110, 1), (115, 1), (139, 1), (140, 6)],
                (100, 108, 10, 5),
            ),
        ] {
            assert_eq!(row(&listings), Some(expected), "{name}");
        }
    }

    #[test]
    fn listings_without_units_have_no_row() {
        assert_eq!(row(&[]), None);
        assert_eq!(row(&[(100, 0), (120, 0)]), None);
        assert_eq!(row(&[(100, 0), (120, 1)]), Some((100, 120, 1, 2)));
    }
}

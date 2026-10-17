use super::*;
fn scan() -> Value {
    json!({"realm":"Faramon","faction":"Horde","region":"EU","scannedAt":1760000016,"mode":"replicate","scanner":"Sultan","build":"1.60.1.70338","rows":[["2589",100,105,100,4],["7070",334,334,3,1]],"items":{"2589":["Linen Cloth",1]}})
}
fn account() -> Value {
    json!({"id":"K7Q2M9PX","keyHash":key_hash("7KQ2M9PXABCDEFGHJKMN"),"characters":[{"name":"Sultan","realm":"Faramon","faction":null,"class":null,"level":null,"updatedAt":null,"gold":[[1791932400u64,5000]],"bags":null,"bank":null}]})
}
#[test]
fn normalized_key_matches_existing_accounts() {
    assert_eq!(normalize_code("o0 iI lL u"), "001111");
    assert_eq!(
        key_hash("7kq2m-9pxab-cdefg-hjkmn"),
        "1f2a4b22637651b9c0e4169e248acbe887d2e3d0ea98321f1bf1452f9b6ecb79"
    );
}
#[test]
fn scan_identity_is_order_independent_and_ignores_names() {
    let original = parse_scan_upload(&scan()).unwrap();
    let mut edited = original.clone();
    edited.rows.reverse();
    edited.items.clear();
    assert_eq!(original.fingerprint(), edited.fingerprint());
    edited.rows[0].1 += 1;
    assert_ne!(original.fingerprint(), edited.fingerprint());
}
#[test]
fn validation_matches_js_safe_integer_and_utf16_limits() {
    let mut v = scan();
    v["realm"] = json!("😀".repeat(33));
    assert_eq!(
        parse_scan_upload(&v).unwrap_err(),
        "realm must be a string of 1 to 64 characters"
    );
    v["realm"] = json!("😀".repeat(32));
    assert!(parse_scan_upload(&v).is_ok());
    v["rows"][0][1] = json!(9_007_199_254_740_992u64);
    assert_eq!(
        parse_scan_upload(&v).unwrap_err(),
        "rows[0] min buyout must be a non-negative integer"
    );
    v["rows"][0][1] = json!(100.0);
    assert!(parse_scan_upload(&v).is_ok());
    v["rows"][0][1] = json!(true);
    assert!(parse_scan_upload(&v).is_err());
}
#[test]
fn scan_contract_preserves_validation_order() {
    for (value, message) in [
        (json!([]), "scan must be an object"),
        (json!({}), "mode must be one of browse, replicate"),
    ] {
        assert_eq!(parse_scan_upload(&value).unwrap_err(), message)
    }
    let mut v = scan();
    v["rows"][1][0] = json!("2589");
    assert_eq!(
        parse_scan_upload(&v).unwrap_err(),
        "rows[1] repeats item key 2589"
    );
    v["rows"][1][0] = json!("7070");
    v["rows"][0][1] = json!(0);
    assert_eq!(
        parse_scan_upload(&v).unwrap_err(),
        "rows[0] min buyout must be positive"
    );
}
#[test]
fn account_is_canonical_and_drops_raw_keys() {
    let mut v = account();
    v["key"] = json!("secret");
    let parsed = parse_account_upload(&v).unwrap();
    let encoded = serde_json::to_string(&parsed).unwrap();
    assert_eq!(
        encoded,
        "{\"id\":\"K7Q2M9PX\",\"keyHash\":\"1f2a4b22637651b9c0e4169e248acbe887d2e3d0ea98321f1bf1452f9b6ecb79\",\"characters\":[{\"name\":\"Sultan\",\"realm\":\"Faramon\",\"faction\":null,\"class\":null,\"level\":null,\"updatedAt\":null,\"gold\":[[1791932400,5000]],\"bags\":null,\"bank\":null}]}"
    );
}
#[test]
fn account_rejects_missing_nullable_fields_and_old_day_numbers() {
    let mut v = account();
    v["characters"][0]
        .as_object_mut()
        .unwrap()
        .remove("faction");
    assert_eq!(
        parse_account_upload(&v).unwrap_err(),
        "characters[0].faction must be one of Alliance, Horde, Neutral or null"
    );
    v = account();
    v["characters"][0]["gold"][0][0] = json!(20738);
    assert_eq!(
        parse_account_upload(&v).unwrap_err(),
        "characters[0].gold[0] must be [time, copper]: a unix time on the hour and a non-negative integer"
    );
    v = account();
    v["previousKeyHash"] = Value::Null;
    assert_eq!(
        parse_account_upload(&v).unwrap_err(),
        "previousKeyHash must be 64 lowercase hex characters"
    );
}
#[test]
fn account_rejections_keep_original_field_messages() {
    let base = json!({"id":"K7Q2M9PX","keyHash":key_hash("7KQ2M9PXABCDEFGHJKMN"),"characters":[{"name":"Sultan","realm":"Faramon","faction":"Horde","class":"WARRIOR","level":60,"updatedAt":1791970261,"gold":[[1791932400u64,5000]],"bags":{"at":null,"rows":[{"key":"2589","name":"Linen Cloth","quality":1,"count":20,"action":"auction","post":40,"vendor":13,"value":760}]},"bank":null}]});
    let cases = vec![
        (
            "/id",
            json!("K7Q2M9PU"),
            "id must be 8 characters of the login code alphabet",
        ),
        (
            "/keyHash",
            json!("RAWKEY"),
            "keyHash must be 64 lowercase hex characters",
        ),
        (
            "/characters",
            json!(vec![base["characters"][0].clone(); 51]),
            "characters must be an array of at most 50 entries",
        ),
        (
            "/characters/0",
            json!("Sultan"),
            "characters[0] must be an object",
        ),
        (
            "/characters/0/name",
            json!(""),
            "characters[0].name must be a string of 1 to 64 characters",
        ),
        (
            "/characters/0/realm",
            json!("R".repeat(65)),
            "characters[0].realm must be a string of 1 to 64 characters",
        ),
        (
            "/characters/0/faction",
            json!("Goblin"),
            "characters[0].faction must be one of Alliance, Horde, Neutral or null",
        ),
        (
            "/characters/0/class",
            json!("M".repeat(21)),
            "characters[0].class must be a string of 1 to 20 characters or null",
        ),
        (
            "/characters/0/level",
            json!(60.5),
            "characters[0].level must be an integer from 1 to 100 or null",
        ),
        (
            "/characters/0/updatedAt",
            json!(-1),
            "characters[0].updatedAt must be a non-negative integer or null",
        ),
        (
            "/characters/0/gold",
            json!(vec![json!([1791932400u64, 1]); 1501]),
            "characters[0].gold must be an array of at most 1500 entries",
        ),
        (
            "/characters/0/gold/0",
            json!([1791932401u64, 1]),
            "characters[0].gold[0] must be [time, copper]: a unix time on the hour and a non-negative integer",
        ),
        (
            "/characters/0/bags",
            json!("full"),
            "characters[0].bags must be an object or null",
        ),
        (
            "/characters/0/bags/at",
            json!(1.5),
            "characters[0].bags.at must be a non-negative integer or null",
        ),
        (
            "/characters/0/bags/rows",
            json!(vec![base["characters"][0]["bags"]["rows"][0].clone(); 1001]),
            "characters[0].bags.rows must be an array of at most 1000 entries",
        ),
        (
            "/characters/0/bags/rows/0",
            json!("2589"),
            "characters[0].bags.rows[0] must be an object",
        ),
        (
            "/characters/0/bags/rows/0/key",
            json!("Linen Cloth"),
            "characters[0].bags.rows[0].key must look like \"2589\" or \"9775:584\"",
        ),
        (
            "/characters/0/bags/rows/0/name",
            json!("L".repeat(201)),
            "characters[0].bags.rows[0].name must be a string of 0 to 200 characters or null",
        ),
        (
            "/characters/0/bags/rows/0/quality",
            json!(9),
            "characters[0].bags.rows[0].quality must be an integer from 0 to 8",
        ),
        (
            "/characters/0/bags/rows/0/count",
            json!(0),
            "characters[0].bags.rows[0].count must be a positive integer",
        ),
        (
            "/characters/0/bags/rows/0/action",
            json!("sell"),
            "characters[0].bags.rows[0].action must be one of auction, vendor, unknown",
        ),
        (
            "/characters/0/bags/rows/0/post",
            json!(-1),
            "characters[0].bags.rows[0].post must be a non-negative integer or null",
        ),
        (
            "/characters/0/bags/rows/0/vendor",
            json!(null),
            "characters[0].bags.rows[0].vendor must be a non-negative integer",
        ),
        (
            "/characters/0/bags/rows/0/value",
            json!(9_007_199_254_740_992u64),
            "characters[0].bags.rows[0].value must be a non-negative integer",
        ),
    ];
    for (path, value, message) in cases {
        let mut input = base.clone();
        *input.pointer_mut(path).unwrap() = value;
        assert_eq!(parse_account_upload(&input).unwrap_err(), message, "{path}");
    }
}
fn entry(side: &str, item: &str, price: i64) -> Value {
    json!({"name":"Sultan","realm":"Faramon","at":1760000000,"side":side,"item":item,"itemKey":null,"count":1,"price":price,"fee":0})
}
#[test]
fn trades_book_every_accounting_side() {
    let sides = "sell buy vendor merchant tradeSell tradeBuy tradeIn tradeOut mailIn mailOut cod \
        quest loot repair postage deposit travel training respec otherIn otherOut";
    for side in sides.split_whitespace() {
        assert_eq!(
            parse_trade(&entry(side, "Gold", 500), "t")
                .map(|t| t.side)
                .as_deref(),
            Ok(side)
        );
    }
    assert_eq!(
        parse_trade(&entry("gift", "Gold", 500), "t").unwrap_err(),
        "t.side must be one of sell, buy, vendor, merchant, tradeSell, tradeBuy, tradeIn, tradeOut, mailIn, mailOut, cod, quest, loot, repair, postage, deposit, travel, training, respec, otherIn, otherOut"
    );
}
#[test]
fn only_an_item_in_a_player_trade_goes_for_nothing() {
    for side in ["tradeSell", "tradeBuy"] {
        assert_eq!(
            parse_trade(&entry(side, "Linen Cloth", 0), "t").map(|t| t.price),
            Ok(0)
        );
        assert_eq!(
            parse_trade(&entry(side, "Linen Cloth", -1), "t").unwrap_err(),
            "t.price must be a non-negative integer"
        );
    }
    for side in ["sell", "merchant", "cod", "mailIn", "loot"] {
        assert_eq!(
            parse_trade(&entry(side, "Gold", 0), "t").unwrap_err(),
            "t.price must be a positive integer",
            "{side}"
        );
    }
    let mut cut = entry("tradeSell", "Linen Cloth", 2000);
    cut["fee"] = json!(100);
    assert_eq!(
        parse_trade(&cut, "t").unwrap_err(),
        "t.fee must not exceed the price, and only an auction sale has one"
    );
}
#[test]
fn a_party_is_optional_text_that_travels_only_when_known() {
    let mut mail = entry("mailIn", "Thanks for the help", 12000);
    assert_eq!(
        serde_json::to_string(&parse_trade(&mail, "t").unwrap()).unwrap(),
        "{\"name\":\"Sultan\",\"realm\":\"Faramon\",\"at\":1760000000,\"side\":\"mailIn\",\"item\":\"Thanks for the help\",\"itemKey\":null,\"count\":1,\"price\":12000,\"fee\":0}"
    );
    mail["party"] = json!("Mirelle");
    assert_eq!(
        serde_json::to_string(&parse_trade(&mail, "t").unwrap()).unwrap(),
        "{\"name\":\"Sultan\",\"realm\":\"Faramon\",\"at\":1760000000,\"side\":\"mailIn\",\"item\":\"Thanks for the help\",\"itemKey\":null,\"count\":1,\"price\":12000,\"fee\":0,\"party\":\"Mirelle\"}"
    );
    mail["party"] = Value::Null;
    assert_eq!(parse_trade(&mail, "t").unwrap().party, None);
    mail["party"] = json!("M".repeat(64));
    assert_eq!(
        parse_trade(&mail, "t").unwrap().party.map(|p| p.len()),
        Some(64)
    );
    for party in [json!(""), json!("M".repeat(65)), json!(7)] {
        mail["party"] = party;
        assert_eq!(
            parse_trade(&mail, "t").unwrap_err(),
            "t.party must be a string of 1 to 64 characters"
        );
    }
}

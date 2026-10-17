//! A data parser for WoW SavedVariables. It never evaluates Lua code.
use anyhow::{Result, bail};
use regex::bytes::Regex;
use serde_json::{Map, Value, json};
use std::{path::Path, sync::LazyLock};

pub type SavedVariables = Map<String, Value>;
static NUMBER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^-?(?:0x[0-9a-f]+|\d+\.?\d*(?:e[+-]?\d+)?|\.\d+(?:e[+-]?\d+)?)").unwrap()
});
static NONFINITE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^-?(?:inf|nan(?:\(\w+\))?|1\.#(?:INF|IND|QNAN))").unwrap());
struct Parser<'a> {
    source: &'a [u8],
    pos: usize,
    depth: usize,
}
impl Parser<'_> {
    fn fail<T>(&self, message: &str) -> Result<T> {
        bail!("{message} at byte {}", self.pos)
    }
    fn skip(&mut self) {
        loop {
            match self.source.get(self.pos) {
                Some(b' ' | b'\t' | b'\n' | b'\r') => self.pos += 1,
                Some(b'-') if self.source.get(self.pos + 1) == Some(&b'-') => {
                    while self.source.get(self.pos).is_some_and(|b| *b != b'\n') {
                        self.pos += 1
                    }
                }
                _ => return,
            }
        }
    }
    fn expect(&mut self, b: u8) -> Result<()> {
        self.skip();
        if self.source.get(self.pos) != Some(&b) {
            return self.fail(&format!("expected \"{}\"", b as char));
        }
        self.pos += 1;
        Ok(())
    }
    fn name(&mut self) -> Option<String> {
        let start = self.pos;
        let first = *self.source.get(start)?;
        if !(first.is_ascii_alphabetic() || first == b'_') {
            return None;
        }
        self.pos += 1;
        while self
            .source
            .get(self.pos)
            .is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_')
        {
            self.pos += 1
        }
        Some(String::from_utf8_lossy(&self.source[start..self.pos]).into_owned())
    }
    fn string(&mut self) -> Result<String> {
        let quote = self.source[self.pos];
        self.pos += 1;
        let mut bytes = Vec::new();
        loop {
            let Some(&b) = self.source.get(self.pos) else {
                return self.fail("unterminated string");
            };
            self.pos += 1;
            if b == quote {
                return Ok(String::from_utf8_lossy(&bytes).into_owned());
            }
            if b != b'\\' {
                bytes.push(b);
                continue;
            }
            let Some(&b) = self.source.get(self.pos) else {
                return self.fail("unknown escape");
            };
            if b.is_ascii_digit() {
                let start = self.pos;
                while self.pos - start < 3
                    && self.source.get(self.pos).is_some_and(u8::is_ascii_digit)
                {
                    self.pos += 1
                }
                let n = std::str::from_utf8(&self.source[start..self.pos])?.parse::<u16>()?;
                bytes.push(n as u8);
            } else {
                let escaped = match b {
                    b'n' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'a' => 7,
                    b'b' => 8,
                    b'f' => 12,
                    b'v' => 11,
                    b'\\' => b'\\',
                    b'"' => b'"',
                    b'\'' => b'\'',
                    b'\n' => b'\n',
                    _ => return self.fail("unknown escape"),
                };
                bytes.push(escaped);
                self.pos += 1
            }
        }
    }
    fn table(&mut self) -> Result<Value> {
        self.pos += 1;
        self.depth += 1;
        if self.depth > 128 {
            return self.fail("table nesting exceeds 128");
        }
        let mut positional = Vec::new();
        let mut keyed = Vec::new();
        loop {
            self.skip();
            if self.source.get(self.pos) == Some(&b'}') {
                self.pos += 1;
                break;
            }
            if self.source.get(self.pos) == Some(&b'[') {
                self.pos += 1;
                let key = self.value()?;
                let key = match key {
                    Value::String(s) => s,
                    Value::Number(n) => n.to_string(),
                    _ => return self.fail("unsupported table key"),
                };
                self.expect(b']')?;
                self.expect(b'=')?;
                keyed.push((key, self.value()?));
            } else {
                positional.push(self.value()?)
            }
            self.skip();
            if matches!(self.source.get(self.pos), Some(b',' | b';')) {
                self.pos += 1
            }
        }
        self.depth -= 1;
        if keyed.is_empty() {
            return Ok(Value::Array(positional));
        }
        let mut map = Map::new();
        for (i, v) in positional.into_iter().enumerate() {
            map.insert((i + 1).to_string(), v);
        }
        for (k, v) in keyed {
            map.insert(k, v);
        }
        Ok(Value::Object(map))
    }
    fn value(&mut self) -> Result<Value> {
        self.skip();
        match self.source.get(self.pos) {
            Some(b'{') => return self.table(),
            Some(b'"' | b'\'') => return self.string().map(Value::String),
            _ => (),
        }
        if let Some(m) = NONFINITE.find(&self.source[self.pos..]) {
            let s = String::from_utf8_lossy(m.as_bytes()).into_owned();
            self.pos += m.len();
            return Ok(json!({"$goldbookNonFinite":s}));
        }
        if let Some(m) = NUMBER.find(&self.source[self.pos..]) {
            let s = std::str::from_utf8(m.as_bytes())?;
            self.pos += m.len();
            let n = if s.trim_start_matches('-').to_lowercase().starts_with("0x") {
                let unsigned = s.trim_start_matches('-');
                let n = u64::from_str_radix(&unsigned[2..], 16)? as f64;
                if s.starts_with('-') { -n } else { n }
            } else {
                s.parse::<f64>()?
            };
            if !n.is_finite() {
                return Ok(json!({"$goldbookNonFinite":s}));
            }
            return Ok(if n.fract() == 0.0 && n >= 0.0 && n <= u64::MAX as f64 {
                json!(n as u64)
            } else if n.fract() == 0.0 && n >= i64::MIN as f64 && n < 0.0 {
                json!(n as i64)
            } else {
                json!(n)
            });
        }
        match self.name().as_deref() {
            Some("true") => Ok(Value::Bool(true)),
            Some("false") => Ok(Value::Bool(false)),
            Some("nil") => Ok(Value::Null),
            _ => self.fail("unexpected value"),
        }
    }
}
/// Non-finite C-runtime literals are represented by a private tagged object so
/// they remain invalid numbers during contract validation instead of becoming nil.
pub fn parse_saved_variables(source: impl AsRef<[u8]>) -> Result<SavedVariables> {
    let mut p = Parser {
        source: source.as_ref(),
        pos: 0,
        depth: 0,
    };
    let mut vars = Map::new();
    loop {
        p.skip();
        if p.pos == p.source.len() {
            return Ok(vars);
        }
        let name = p
            .name()
            .ok_or_else(|| anyhow::anyhow!("expected a variable name at byte {}", p.pos))?;
        p.expect(b'=')?;
        vars.insert(name, p.value()?);
    }
}
pub fn read_saved_variables(path: &Path) -> Result<SavedVariables> {
    parse_saved_variables(std::fs::read(path)?)
}
/// JSON.stringify compatibility for scan identity; JS turns non-finite numbers into null.
pub(crate) fn js_value(value: &Value) -> Value {
    match value {
        Value::Object(m) if m.len() == 1 && m.contains_key("$goldbookNonFinite") => Value::Null,
        Value::Object(m) => {
            Value::Object(m.iter().map(|(k, v)| (k.clone(), js_value(v))).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(js_value).collect()),
        v => v.clone(),
    }
}

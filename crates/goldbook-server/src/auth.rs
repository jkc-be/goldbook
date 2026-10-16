use std::{
    collections::HashMap,
    net::{IpAddr, Ipv6Addr},
};

const WINDOW: i64 = 900;

#[derive(Clone)]
pub(crate) struct Network {
    address: IpAddr,
    prefix: u8,
}
impl Network {
    pub fn parse(value: &str) -> anyhow::Result<Self> {
        let (ip, prefix) = value
            .split_once('/')
            .map_or((value, None), |(ip, p)| (ip, Some(p)));
        let address: IpAddr = ip.parse()?;
        let bits = if address.is_ipv4() { 32 } else { 128 };
        let prefix = prefix.map(str::parse).transpose()?.unwrap_or(bits);
        anyhow::ensure!(prefix <= bits, "invalid network prefix: {value}");
        Ok(Self { address, prefix })
    }
    fn contains(&self, address: IpAddr) -> bool {
        match (self.address, mapped(address)) {
            (IpAddr::V4(a), IpAddr::V4(b)) => {
                self.prefix == 0
                    || u32::from(a) >> (32 - self.prefix) == u32::from(b) >> (32 - self.prefix)
            }
            (IpAddr::V6(a), IpAddr::V6(b)) => {
                self.prefix == 0
                    || u128::from(a) >> (128 - self.prefix) == u128::from(b) >> (128 - self.prefix)
            }
            _ => false,
        }
    }
}
fn mapped(address: IpAddr) -> IpAddr {
    match address {
        IpAddr::V6(ip) => ip.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(address),
        _ => address,
    }
}
fn network(address: &str) -> String {
    match address.parse::<IpAddr>().map(mapped) {
        Ok(IpAddr::V6(ip)) => Ipv6Addr::from(u128::from(ip) & (u128::MAX << 64)).to_string(),
        Ok(ip) => ip.to_string(),
        Err(_) => address.into(),
    }
}
pub(crate) fn client_address(sender: &str, forwarded: &str, proxies: &[Network]) -> Option<String> {
    let Ok(ip) = sender.parse::<IpAddr>() else {
        return Some(sender.into());
    };
    let trusted = |ip| proxies.iter().any(|p| p.contains(ip));
    if forwarded.is_empty() || !trusted(ip) {
        return Some(sender.into());
    }
    let last = forwarded.rsplit(',').next().unwrap_or("").trim();
    match last.parse::<IpAddr>() {
        Ok(visitor) if trusted(visitor) => None,
        Ok(visitor) => Some(visitor.to_string()),
        Err(_) => Some(sender.into()),
    }
}
#[derive(Default)]
pub(crate) struct LoginLimits {
    failures: HashMap<Vec<String>, Vec<i64>>,
    swept: i64,
}
fn keys(id: Option<&str>, address: Option<&str>) -> Vec<(Vec<String>, usize)> {
    let mut keys = Vec::new();
    if let Some(address) = address {
        let address = network(address);
        if let Some(id) = id {
            keys.push((vec!["pair".into(), id.into(), address.clone()], 5));
        }
        keys.push((vec!["address".into(), address], 20));
    }
    if let Some(id) = id {
        keys.push((vec!["id".into(), id.into()], 200));
    }
    keys
}
impl LoginLimits {
    pub fn begin(&mut self, id: Option<&str>, address: Option<&str>, now: i64) -> i64 {
        if now - self.swept >= WINDOW {
            self.swept = now;
            self.failures.retain(|_, times| {
                times.retain(|t| *t > now - WINDOW);
                !times.is_empty()
            });
        }
        let keys = keys(id, address);
        let mut wait = 0;
        for (key, limit) in &keys {
            if let Some(times) = self.failures.get_mut(key) {
                times.retain(|t| *t > now - WINDOW);
                if times.len() >= *limit {
                    wait = wait.max(times[times.len() - limit] + WINDOW - now);
                }
            }
        }
        if wait == 0 {
            for (key, _) in keys {
                self.failures.entry(key).or_default().push(now);
            }
        }
        wait
    }
    pub fn succeed(&mut self, id: &str, address: Option<&str>, at: i64) {
        for (key, _) in keys(Some(id), address) {
            if key[0] == "pair" {
                self.failures.remove(&key);
            } else if let Some(times) = self.failures.get_mut(&key)
                && let Some(i) = times.iter().position(|t| *t == at)
            {
                times.remove(i);
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn limits_failures_and_resets_a_successful_pair() {
        let mut limiter = LoginLimits::default();
        for _ in 0..5 {
            assert_eq!(limiter.begin(Some("id"), Some("2001:db8::1"), 1000), 0);
        }
        assert_eq!(limiter.begin(Some("id"), Some("2001:db8::2"), 1000), 900);
        limiter.succeed("id", Some("2001:db8::1"), 1000);
        assert_eq!(limiter.begin(Some("id"), Some("2001:db8::2"), 1000), 0);
        assert_eq!(limiter.begin(Some("id"), Some("2001:db8::2"), 1900), 0);
    }
    #[test]
    fn proxy_only_trusts_the_last_address_from_a_known_sender() {
        let proxies = [Network::parse("172.19.0.0/16").unwrap()];
        assert_eq!(
            client_address("::ffff:172.19.0.2", "8.8.8.8, 172.19.0.1", &proxies),
            None
        );
        assert_eq!(
            client_address("172.20.0.1", "8.8.8.8", &proxies),
            Some("172.20.0.1".into())
        );
        assert_eq!(
            client_address("172.19.0.2", "8.8.8.8, 1.1.1.1", &proxies),
            Some("1.1.1.1".into())
        );
    }
}

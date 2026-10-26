//! Where the Axo relay service lives.

use std::io;

use url::{Host, Url};

/// The production relay. Builds can point elsewhere with `--relay-url` / `AXO_RELAY_URL`.
pub const DEFAULT_RELAY_URL: &str = "https://axo.leostera.dev";

/// The relay's origin, parsed. Remote relays must use TLS; plain `http`/`ws` is accepted only
/// for a loopback relay, which never leaves the machine (isolated tests and local Workers).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RelayEndpoint {
    /// Always `https` or, for loopback only, `http`; WebSocket URLs are derived from it.
    origin: Url,
}

impl RelayEndpoint {
    pub fn parse(raw: &str) -> io::Result<Self> {
        let invalid = |reason: &str| io::Error::new(io::ErrorKind::InvalidInput, reason.to_owned());
        let mut origin = Url::parse(raw.trim()).map_err(|_| invalid("relay URL is invalid"))?;
        if !origin.username().is_empty()
            || origin.password().is_some()
            || origin.query().is_some()
            || origin.fragment().is_some()
            || !matches!(origin.path(), "" | "/")
        {
            return Err(invalid(
                "relay URL must be an origin without credentials, path, query, or fragment",
            ));
        }
        let scheme = match origin.scheme() {
            "https" | "wss" => "https",
            "http" | "ws" if is_loopback(&origin) => "http",
            _ => {
                return Err(invalid(
                    "relay URL must use https; plain http is allowed only for a loopback relay",
                ));
            }
        };
        origin
            .set_scheme(scheme)
            .map_err(|_| invalid("relay URL is invalid"))?;
        Ok(Self { origin })
    }

    pub fn production() -> Self {
        Self::parse(DEFAULT_RELAY_URL).expect("the production relay URL is valid")
    }

    /// The account-scoped WebSocket this host connects to once linked.
    pub(crate) fn daemon_url(&self, account_id: &str, host_id: &str) -> Url {
        let mut url = self.at(&format!(
            "/api/v1/accounts/{account_id}/hosts/{host_id}/daemon"
        ));
        let scheme = if self.origin.scheme() == "https" {
            "wss"
        } else {
            "ws"
        };
        url.set_scheme(scheme)
            .expect("http(s) origins convert to ws(s)");
        url
    }

    /// Where a pairing code is redeemed.
    pub(crate) fn redemption_url(&self) -> Url {
        self.at("/api/v1/host-pairings/redeem")
    }

    fn at(&self, path: &str) -> Url {
        let mut url = self.origin.clone();
        url.set_path(path);
        url
    }
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::RelayEndpoint;

    const ACCOUNT: &str = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
    const HOST: &str = "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe";

    #[test]
    fn remote_relays_use_tls_and_loopback_relays_may_not() {
        let production = RelayEndpoint::production();
        assert_eq!(
            production.daemon_url(ACCOUNT, HOST).as_str(),
            format!("wss://axo.leostera.dev/api/v1/accounts/{ACCOUNT}/hosts/{HOST}/daemon")
        );
        assert_eq!(
            production.redemption_url().as_str(),
            "https://axo.leostera.dev/api/v1/host-pairings/redeem"
        );
        assert_eq!(
            RelayEndpoint::parse("wss://axo.example.test/").unwrap(),
            RelayEndpoint::parse("https://axo.example.test").unwrap()
        );

        let local = RelayEndpoint::parse("http://127.0.0.1:8787").unwrap();
        assert_eq!(
            local.daemon_url(ACCOUNT, HOST).as_str(),
            format!("ws://127.0.0.1:8787/api/v1/accounts/{ACCOUNT}/hosts/{HOST}/daemon")
        );
        assert_eq!(
            local.redemption_url().as_str(),
            "http://127.0.0.1:8787/api/v1/host-pairings/redeem"
        );
        assert!(RelayEndpoint::parse("ws://[::1]:9").is_ok());
        assert!(RelayEndpoint::parse("http://localhost:9").is_ok());
    }

    #[test]
    fn anything_but_a_relay_origin_is_refused() {
        for raw in [
            "http://axo.example.test",
            "ws://10.0.0.1",
            "ftp://axo.example.test",
            "https://user:secret@axo.example.test",
            "https://axo.example.test/api",
            "https://axo.example.test/?q=1",
            "https://axo.example.test/#x",
            "not a url",
            "",
        ] {
            assert!(RelayEndpoint::parse(raw).is_err(), "{raw}");
        }
    }
}

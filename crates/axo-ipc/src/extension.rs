//! Extensions: the parts of axod that offer methods (RFD0034 step 4).
//!
//! An extension registers its methods once, when the server is assembled, into [`Methods`],
//! which owns the one handler the transport serves. Each method has one owner: a name two
//! extensions register is refused, where jsonrpc-core would keep whichever came last.
//!
//! Not yet here (RFD0034): typed request contexts, per-method callers for the relay, background
//! tasks, and services one extension exports to others.

use std::collections::BTreeMap;
use std::fmt;

use jsonrpc_core::IoHandler;

/// A part of axod that offers methods.
pub trait Extension: Send + Sync {
    /// What it is called in logs and conflicts, such as `"apps"`.
    fn name(&self) -> &'static str;

    /// Registers its methods. Called once, before the server takes requests.
    fn register(&self, methods: &mut IoHandler);
}

/// Two extensions registered the same method.
#[derive(Debug, Eq, PartialEq)]
pub struct Conflict {
    pub method: String,
    pub first: &'static str,
    pub second: &'static str,
}

impl fmt::Display for Conflict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} is registered by both {} and {}",
            self.method, self.first, self.second
        )
    }
}

impl std::error::Error for Conflict {}

/// Every extension's methods, and which extension owns each.
#[derive(Default)]
pub struct Methods {
    handler: IoHandler,
    owners: BTreeMap<String, &'static str>,
}

impl Methods {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds `extension`'s methods. On a conflict nothing of it is added.
    pub fn add(&mut self, extension: &dyn Extension) -> Result<&mut Self, Conflict> {
        let mut own = IoHandler::new();
        extension.register(&mut own);
        let names: Vec<String> = own.iter().map(|(name, _)| name.clone()).collect();
        if let Some((method, first)) = names
            .iter()
            .find_map(|name| self.owners.get(name).map(|first| (name.clone(), *first)))
        {
            return Err(Conflict {
                method,
                first,
                second: extension.name(),
            });
        }
        for name in names {
            self.owners.insert(name, extension.name());
        }
        self.handler.extend_with(own);
        Ok(self)
    }

    /// The extension that owns `method`.
    pub fn owner(&self, method: &str) -> Option<&'static str> {
        self.owners.get(method).copied()
    }

    /// Every method, by name, with its owner.
    pub fn owners(&self) -> impl Iterator<Item = (&str, &'static str)> {
        self.owners
            .iter()
            .map(|(name, owner)| (name.as_str(), *owner))
    }

    /// The handler the transport serves.
    pub fn into_handler(self) -> IoHandler {
        self.handler
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonrpc_core::Value;

    struct Named(&'static str, &'static [&'static str]);

    impl Extension for Named {
        fn name(&self) -> &'static str {
            self.0
        }
        fn register(&self, methods: &mut IoHandler) {
            let owner = self.0;
            for &method in self.1 {
                methods.add_sync_method(method, move |_| Ok(Value::String(owner.into())));
            }
        }
    }

    #[test]
    fn each_method_has_one_owner_and_answers_as_it() {
        let mut methods = Methods::new();
        methods
            .add(&Named("sessions", &["axo.session.list"]))
            .unwrap()
            .add(&Named("apps", &["axo.apps.list", "axo.apps.run"]))
            .unwrap();
        assert_eq!(methods.owner("axo.apps.run"), Some("apps"));
        assert_eq!(methods.owner("axo.nothing"), None);
        assert_eq!(methods.owners().count(), 3);
        let handler = methods.into_handler();
        let reply = handler
            .handle_request_sync(r#"{"jsonrpc":"2.0","id":1,"method":"axo.session.list"}"#)
            .unwrap();
        assert!(reply.contains(r#""result":"sessions""#), "{reply}");
    }

    #[test]
    fn a_method_two_extensions_register_is_refused_and_the_second_adds_nothing() {
        let mut methods = Methods::new();
        methods
            .add(&Named("sessions", &["axo.session.list"]))
            .unwrap();
        let conflict = methods
            .add(&Named("intruder", &["axo.other", "axo.session.list"]))
            .err()
            .unwrap();
        assert_eq!(
            conflict.to_string(),
            "axo.session.list is registered by both sessions and intruder"
        );
        assert_eq!(methods.owner("axo.other"), None, "nothing of it was added");
        assert_eq!(methods.owner("axo.session.list"), Some("sessions"));
    }
}

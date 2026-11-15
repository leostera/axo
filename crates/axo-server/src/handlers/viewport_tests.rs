use super::*;

#[tokio::test(flavor = "multi_thread")]
async fn viewport_versions_are_checked_before_any_mutation() {
    let fixture = crate::test_support::Fixture::new().await;
    let mut methods = IoHandler::new();
    Sessions(Arc::clone(&fixture.core)).register(&mut methods);
    let native = Viewport::from_native_metrics(
        axo_protocol::Size {
            width: 102.0,
            height: 100.0,
        },
        1.5,
        axo_protocol::PixelSize {
            width: 8,
            height: 18,
        },
        axo_protocol::Padding {
            top: 3,
            bottom: 3,
            left: 2,
            right: 2,
        },
        1.0,
        axo_protocol::ViewportOrigin::default(),
    )
    .unwrap();
    for (method, viewport) in [
        (method::CLIENT_VIEWPORT_SET, native),
        (method::CLIENT_VIEWPORT_SET_V2, native.legacy_projection()),
    ] {
        let request = serde_json::json!({"jsonrpc":"2.0","id":1,"method":method,"params":viewport});
        let response: serde_json::Value =
            serde_json::from_str(&methods.handle_request(&request.to_string()).await.unwrap())
                .unwrap();
        assert_eq!(response["error"]["code"], -32602);
        assert_eq!(*fixture.core.viewport.borrow(), None);
    }
    for (method, viewport) in [
        (method::CLIENT_VIEWPORT_SET_V2, native),
        (method::CLIENT_VIEWPORT_SET, native.legacy_projection()),
    ] {
        let request = serde_json::json!({"jsonrpc":"2.0","id":1,"method":method,"params":viewport});
        let response: serde_json::Value =
            serde_json::from_str(&methods.handle_request(&request.to_string()).await.unwrap())
                .unwrap();
        assert_eq!(response["result"]["accepted"], true);
        assert_eq!(*fixture.core.viewport.borrow(), Some(viewport));
    }
}

use super::*;
use axo_protocol::{SessionId, ShellId};

fn sid() -> SessionId {
    SessionId::from_u128(1)
}
fn pane() -> ShellId {
    ShellId::new(7).unwrap()
}
fn record() -> Value {
    json!({"id":sid(),"name":"fixture","status":"ready","folder":"/tmp/fixture",
        "shells":[{"id":7,"role":"pi","processId":123,"initialPwd":"/tmp/fixture","ptyDevice":"/dev/pts/1",
            "attachSocketPath":"/tmp/fixture/attach.sock","available":true,"availabilityReason":null}],
        "layout":{"kind":"pane","shellId":7}})
}

#[tokio::test]
async fn typed_payload_failure_closes_an_otherwise_aligned_connection() {
    let (mut client, mut server) = pair();
    let task = tokio::spawn(async move {
        request(&mut server).await;
        reply(
            &mut server,
            json!({"jsonrpc":"2.0","id":1,"result":"not a number"}),
        )
        .await;
        assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
    });
    assert!(client.call_typed::<u32>("test", json!({})).await.is_err());
    assert!(client.stream.is_none());
    assert!(client.call("test", json!({})).await.is_err());
    task.await.unwrap();
}

#[tokio::test]
async fn creation_encodes_home_folder_and_current_context_once() {
    for (create, params) in [
        (rpc::CreateSession::default(), json!({})),
        (
            rpc::SessionLocation::InFolder("/tmp/fixture".into()).into(),
            json!({"folder":"/tmp/fixture"}),
        ),
        (
            rpc::SessionLocation::Like(SessionId::from_u128(2)).into(),
            json!({"like":SessionId::from_u128(2)}),
        ),
        (
            rpc::CreateSession {
                location: rpc::SessionLocation::Like(SessionId::from_u128(2)),
                name: Some(rpc::SessionName::parse("named fixture".into()).unwrap()),
            },
            json!({"like":SessionId::from_u128(2),"name":"named fixture"}),
        ),
        (
            serde_json::from_value(json!({"folder":"/tmp/fixture","name":"named Session"}))
                .unwrap(),
            json!({"folder":"/tmp/fixture","name":"named Session"}),
        ),
    ] {
        let (mut client, mut server) = pair();
        client.methods = vec![rpc::method::SESSION_CREATE.into()];
        let task = tokio::spawn(async move {
            let call = request(&mut server).await;
            assert_eq!(call["method"], rpc::method::SESSION_CREATE);
            assert_eq!(call["params"], params);
            reply(
                &mut server,
                json!({"jsonrpc":"2.0","id":call["id"],"result":record()}),
            )
            .await;
        });
        assert_eq!(client.create_session(create).await.unwrap().id, sid());
        task.await.unwrap();
    }
}

#[tokio::test]
async fn relative_folder_and_unadvertised_auto_wake_send_nothing_and_never_force() {
    let (mut client, mut server) = pair();
    client.methods = vec![
        rpc::method::SESSION_CREATE.into(),
        rpc::method::SESSION_PI_RESTART_FORCE.into(),
    ];
    assert!(matches!(
        client
            .create_session(rpc::SessionLocation::InFolder("relative".into()).into())
            .await,
        Err(Error::Input(_))
    ));
    assert!(client.wake_pi(sid(), pane()).await.is_err());
    assert!(client.stream.is_some());
    assert_eq!(
        server.get_mut().try_read(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[tokio::test]
async fn wake_checks_the_exact_available_pi_and_sends_only_auto() {
    let (mut client, mut server) = pair();
    client.methods = vec![
        rpc::method::SESSION_PI_RESTART_AUTO.into(),
        rpc::method::SESSION_PI_RESTART_FORCE.into(),
    ];
    let task = tokio::spawn(async move {
        let call = request(&mut server).await;
        assert_eq!(call["method"], rpc::method::SESSION_PI_RESTART_AUTO);
        assert_eq!(call["params"], json!({"sessionId":sid(),"shellId":pane()}));
        reply(
            &mut server,
            json!({"jsonrpc":"2.0","id":call["id"],"result":record()}),
        )
        .await;
    });
    assert_eq!(client.wake_pi(sid(), pane()).await.unwrap().id, sid());
    task.await.unwrap();
}

#[tokio::test]
async fn malformed_or_misdirected_action_results_are_fenced_not_replayed() {
    for variant in 0..9 {
        let (mut client, mut server) = pair();
        client.methods = vec![
            rpc::method::SESSION_CREATE.into(),
            rpc::method::SESSION_PI_RESTART_AUTO.into(),
        ];
        let mut result = record();
        match variant {
            0 => result = json!({}),
            1 => result["shells"][0]["attachSocketPath"] = json!("relative.sock"),
            2 => result["layout"]["shellId"] = json!(99),
            3 => result["folder"] = json!("relative"),
            4 => result["id"] = json!(SessionId::from_u128(2)),
            5 => result["shells"][0]["role"] = json!("terminal"),
            6 => result["shells"][0]["available"] = json!(false),
            7 => result["shells"][0]["processId"] = json!(0),
            8 => {} // Creation must not return its source Session.
            _ => unreachable!(),
        }
        let task = tokio::spawn(async move {
            let call = request(&mut server).await;
            reply(
                &mut server,
                json!({"jsonrpc":"2.0","id":call["id"],"result":result}),
            )
            .await;
            assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
        });
        let error = if variant == 8 {
            client
                .create_session(rpc::SessionLocation::Like(sid()).into())
                .await
        } else {
            client.wake_pi(sid(), pane()).await
        };
        assert!(error.is_err(), "variant {variant}");
        assert!(client.stream.is_none(), "variant {variant}");
        task.await.unwrap();
    }
}

#[tokio::test]
async fn admitted_creation_with_lost_ack_is_not_replayed() {
    let (mut client, mut server) = pair();
    client.methods = vec![rpc::method::SESSION_CREATE.into()];
    let task = tokio::spawn(async move {
        let call = request(&mut server).await;
        assert_eq!(call["method"], rpc::method::SESSION_CREATE);
        // Simulate creation being admitted, then lose its acknowledgement.
        drop(server);
    });
    assert!(
        client
            .create_session(rpc::CreateSession::default())
            .await
            .is_err()
    );
    assert!(client.stream.is_none());
    task.await.unwrap();
}

#[tokio::test]
async fn cancelling_creation_after_dispatch_closes_without_replay() {
    let (mut client, mut server) = pair();
    client.methods = vec![rpc::method::SESSION_CREATE.into()];
    let (sent, received) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        request(&mut server).await;
        sent.send(()).unwrap();
        assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
    });
    let mut create = Box::pin(client.create_session(rpc::CreateSession::default()));
    tokio::select! {
        _ = &mut create => panic!("no reply was sent"),
        _ = received => {},
    }
    drop(create);
    assert!(client.stream.is_none());
    task.await.unwrap();
}

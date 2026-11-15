use super::*;

fn pair() -> (Client, BufReader<UnixStream>) {
    let (client, server) = UnixStream::pair().unwrap();
    (
        Client {
            stream: Some(BufReader::new(client)),
            next_id: 0,
            methods: vec!["test".into()],
        },
        BufReader::new(server),
    )
}
async fn request(server: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    server.read_line(&mut line).await.unwrap();
    serde_json::from_str(&line).unwrap()
}
async fn reply(server: &mut BufReader<UnixStream>, value: Value) {
    let mut line = serde_json::to_vec(&value).unwrap();
    line.push(b'\n');
    server.get_mut().write_all(&line).await.unwrap();
}

#[tokio::test]
async fn mismatched_or_ambiguous_replies_poison_the_connection() {
    for response in [
        json!({"jsonrpc":"2.0","id":999,"result":{}}),
        json!({"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"bad"}}),
        json!({"jsonrpc":"2.0","id":1}),
    ] {
        let (mut client, mut server) = pair();
        let task = tokio::spawn(async move {
            request(&mut server).await;
            reply(&mut server, response).await;
        });
        assert!(client.call("test", json!({})).await.is_err());
        assert!(client.stream.is_none());
        task.await.unwrap();
    }
}

#[tokio::test]
async fn cancellation_closes_the_socket_and_cannot_misattribute_a_late_reply() {
    let (mut client, mut server) = pair();
    let (sent, received) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        request(&mut server).await;
        sent.send(()).unwrap();
        assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
    });
    let mut call = Box::pin(client.call("test", json!({})));
    tokio::select! {
        _ = &mut call => panic!("server intentionally sent no response"),
        _ = received => {},
    }
    drop(call);
    assert!(
        client
            .call("test", json!({}))
            .await
            .unwrap_err()
            .to_string()
            .contains("no longer usable")
    );
    task.await.unwrap();
}

#[tokio::test]
async fn rejection_does_not_poison_a_well_framed_connection() {
    let (mut client, mut server) = pair();
    let task = tokio::spawn(async move {
        request(&mut server).await;
        reply(
            &mut server,
            json!({"jsonrpc":"2.0","id":1,"error":{"code":-32003,"message":"not authorized"}}),
        )
        .await;
        let next = request(&mut server).await;
        reply(
            &mut server,
            json!({"jsonrpc":"2.0","id":next["id"],"result":null}),
        )
        .await;
    });
    assert!(matches!(
        client.call("test", json!({})).await,
        Err(Error::Rejected { code: -32003, .. })
    ));
    assert_eq!(client.call("test", json!({})).await.unwrap(), Value::Null);
    task.await.unwrap();
}

#[tokio::test]
async fn unsupported_or_oversized_requests_send_nothing() {
    let (mut client, mut server) = pair();
    assert!(client.call("not-negotiated", json!({})).await.is_err());
    assert!(matches!(
        client.call("test", json!("x".repeat(MAX_REQUEST))).await,
        Err(Error::Input(_))
    ));
    assert!(client.stream.is_some());
    assert_eq!(
        server.get_mut().try_read(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[tokio::test]
async fn unsupported_negotiation_is_not_a_usable_connection() {
    let (mut client, mut server) = pair();
    let task = tokio::spawn(async move {
        request(&mut server).await;
        reply(&mut server, json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":rpc::PROTOCOL_VERSION+1,"methods":["test"]}})).await;
    });
    assert!(client.negotiate().await.is_err());
    assert!(client.stream.is_none());
    task.await.unwrap();
}

#[tokio::test]
async fn typed_results_are_parsed_not_cast() {
    let (mut client, mut server) = pair();
    let task = tokio::spawn(async move {
        request(&mut server).await;
        reply(
            &mut server,
            json!({"jsonrpc":"2.0","id":1,"result":"not-a-session-uuid"}),
        )
        .await;
    });
    assert!(
        client
            .call_typed::<axo_protocol::SessionId>("test", json!({}))
            .await
            .is_err()
    );
    task.await.unwrap();
}

#[tokio::test]
async fn lagged_event_batch_is_delivered_once_then_requires_resubscription() {
    let (reader, writer) = UnixStream::pair().unwrap();
    let mut server = BufReader::new(writer);
    let value = json!({"jsonrpc":"2.0","method":"axo.session.events","params":{"events":[axo_protocol::Event::SubscriptionLagged]}});
    reply(&mut server, value.clone()).await;
    let mut events = EventStream {
        stream: Some(BufReader::new(reader)),
        acknowledgement: json!({}),
    };
    let batch = events.next().await.unwrap();
    assert!(batch.lagged());
    assert_eq!(batch.wire(), &value);
    assert!(events.next().await.is_err());
}

#[tokio::test]
async fn incomplete_and_oversized_frames_are_rejected_and_closed() {
    for bytes in [
        b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".to_vec(),
        vec![b'x'; MAX_FRAME as usize + 1],
    ] {
        let (mut client, mut server) = pair();
        let task = tokio::spawn(async move {
            request(&mut server).await;
            let _ = server.get_mut().write_all(&bytes).await;
        });
        assert!(
            client
                .call("test", json!({}))
                .await
                .unwrap_err()
                .to_string()
                .contains("oversized or incomplete")
        );
        assert!(client.stream.is_none());
        task.await.unwrap();
    }
}

#[tokio::test]
async fn request_ids_do_not_wrap_and_dispatch_again() {
    let (mut client, mut server) = pair();
    client.next_id = u64::MAX;
    assert!(
        client
            .call("test", json!({}))
            .await
            .unwrap_err()
            .to_string()
            .contains("ID space exhausted")
    );
    assert_eq!(
        server.get_mut().try_read(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[tokio::test]
async fn settings_validate_reply_identity_and_never_accept_another_fields_value() {
    use axo_protocol::ConfigKey;
    let (mut client, mut server) = pair();
    client.methods = vec![
        rpc::method::CONFIG_GET.into(),
        rpc::method::CONFIG_SET.into(),
    ];
    let task = tokio::spawn(async move {
        let first = request(&mut server).await;
        assert_eq!(first["params"]["key"], "shell.command");
        reply(&mut server, json!({"jsonrpc":"2.0","id":first["id"],"result":{"key":"shell.command","value":"/bin/sh"}})).await;
        let second = request(&mut server).await;
        assert_eq!(second["method"], rpc::method::CONFIG_SET);
        assert_eq!(second["params"]["value"], "37");
        reply(&mut server, json!({"jsonrpc":"2.0","id":second["id"],"result":{"key":"sessions.idleLimit","value":"37"}})).await;
    });
    assert_eq!(
        client
            .config_value(ConfigKey::ShellCommand)
            .await
            .unwrap()
            .value,
        "/bin/sh"
    );
    assert!(
        client
            .set_config_value(ConfigKey::IdleMinutes, "37")
            .await
            .is_err()
    );
    assert!(client.stream.is_none());
    task.await.unwrap();
}

#[test]
fn catalog_binds_layout_panes_to_their_own_session_and_absolute_socket() {
    fn session(id: u128, shell: i64) -> Value {
        json!({"id":axo_protocol::SessionId::from_u128(id),"name":"fixture","status":"ready","folder":"/tmp/fixture",
            "shells":[{"id":shell,"role":"terminal","processId":1,"initialPwd":"/tmp/fixture","ptyDevice":"/dev/pts/1",
                "attachSocketPath":"/tmp/fixture/attach.sock","available":true,"availabilityReason":null}],
            "layout":{"kind":"pane","shellId":shell}})
    }
    fn parse(sessions: Vec<Value>) -> Result<LocalCatalog, Error> {
        LocalCatalog::try_from(
            serde_json::from_value::<rpc::SessionCatalog>(
                json!({"sessions":sessions,"archived":[]}),
            )
            .unwrap(),
        )
    }
    assert_eq!(
        parse(vec![session(1, 1), session(2, 2)])
            .unwrap()
            .sessions()
            .len(),
        2
    );
    assert!(parse(vec![session(1, 1), session(1, 2)]).is_err());
    assert!(parse(vec![session(1, 1), session(2, 1)]).is_err());
    let mut cross_session = session(1, 1);
    cross_session["layout"]["shellId"] = json!(2);
    assert!(parse(vec![cross_session, session(2, 2)]).is_err());
    let mut relative = session(1, 1);
    relative["shells"][0]["attachSocketPath"] = json!("./attach.sock");
    assert!(parse(vec![relative]).is_err());
    let mut no_layout_yet = session(1, 1);
    no_layout_yet["layout"] = Value::Null;
    assert!(parse(vec![no_layout_yet]).is_ok());
}

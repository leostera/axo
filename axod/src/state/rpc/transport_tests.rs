use super::tests::Fixture;
use crate::{
    client::{Client, ClientError},
    local::LocalServer,
    model::*,
};
use serde_json::json;
use std::sync::{Arc, atomic::AtomicBool};
#[test]
fn actual_websocket_routes_only_central_metadata_and_publishes_new_authority() {
    let fixture = Fixture::new();
    let stopping = Arc::new(AtomicBool::new(false));
    let server = LocalServer::start_central(
        fixture.root.path(),
        fixture.machine,
        fixture.owner.clone(),
        stopping,
    )
    .unwrap();
    let mut client = Client::connect(&fixture.root.path().join("local-endpoint.json")).unwrap();
    let destination = json!({"machineId":client.discovery.machine_id,"hostGeneration":client.discovery.host_generation});
    let bootstrap = client
        .call("axo.state.get", json!({"target":destination}))
        .unwrap();
    assert_eq!(bootstrap["value"]["backendCompleteCreation"], true);
    let mut source = destination;
    source["storeGeneration"] = bootstrap["storeGeneration"].clone();
    let created=client.call("axo.state.workspace.create",json!({"target":source,"commandId":CommandId::new(),"expectedRevision":0,"name":"Workspace","directoryPath":fixture.root.path()})).unwrap();
    assert_eq!(created["value"]["operation"]["kind"], "createWorkspace");
    assert_eq!(
        client.call("axo.session.list", json!({"target":source})),
        Err(ClientError::Rpc(-32601))
    );
    drop(client);
    drop(server);
}

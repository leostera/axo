use super::*;
use std::sync::{
    Mutex,
    atomic::{AtomicUsize, Ordering},
};

struct Prompts {
    decision: Decision,
    password: bool,
    value: String,
    stall: bool,
    marker: Option<PathBuf>,
    calls: AtomicUsize,
    previews: Mutex<Vec<String>>,
}
impl Prompts {
    fn accepting() -> Self {
        Self {
            decision: Decision::Accept,
            password: true,
            value: "synthetic-only-correct".into(),
            stall: false,
            marker: None,
            calls: AtomicUsize::new(0),
            previews: Mutex::new(Vec::new()),
        }
    }
}
impl Prompter for Prompts {
    fn confirm<'a>(
        &'a self,
        preview: &'a str,
        _: Duration,
    ) -> PromptFuture<'a, Result<Decision, Failure>> {
        self.previews.lock().unwrap().push(preview.into());
        Box::pin(async move { Ok(self.decision) })
    }
    fn password<'a>(
        &'a self,
        preview: &'a str,
        _: Duration,
    ) -> PromptFuture<'a, Result<PasswordAnswer, Failure>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(marker) = &self.marker {
            fs::write(marker, b"question started").unwrap();
        }
        self.previews.lock().unwrap().push(preview.into());
        Box::pin(async move {
            if self.stall {
                return std::future::pending().await;
            }
            if !self.password {
                return Ok(PasswordAnswer::Cancel);
            }
            Ok(PasswordAnswer::Accept(
                Password::parse(Zeroizing::new(self.value.clone())).unwrap(),
            ))
        })
    }
}
static TEMP: AtomicUsize = AtomicUsize::new(0);
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "axo-sudo-test-{}-{}",
            std::process::id(),
            TEMP.fetch_add(1, Ordering::SeqCst)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
    fn context(&self) -> Context {
        Context::new(
            self.0.clone(),
            fs::canonicalize(std::env::var("AXO_TEST_ASKPASS").unwrap()).unwrap(),
        )
        .unwrap()
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
async fn execute(mode: &str, prompts: &Prompts, duration: Duration) -> (Receipt, Directory) {
    let directory = Directory::new();
    let mut argv = vec!["/fixture/program".to_owned(), mode.to_owned()];
    if let Some(marker) = &prompts.marker {
        argv.push(marker.to_str().unwrap().into());
    }
    argv.push(
        fs::canonicalize(&directory.0)
            .unwrap()
            .to_str()
            .unwrap()
            .into(),
    );
    let invocation =
        Invocation::parse(serde_json::json!({"target":{"kind":"sudo","argv":argv}})).unwrap();
    let sudo = fs::canonicalize(std::env::var("AXO_TEST_SUDO").unwrap()).unwrap();
    let receipt = run_with(
        invocation,
        directory.context(),
        prompts,
        duration,
        &sudo,
        Ownership::OwnedFixture,
    )
    .await;
    (receipt, directory)
}
#[tokio::test]
async fn password_uses_only_bound_helper_pipe_and_receipt_excludes_command_output() {
    let prompts = Prompts::accepting();
    let (receipt, directory) = execute("password", &prompts, Duration::from_secs(5)).await;
    let receipt = serde_json::to_value(receipt).unwrap();
    assert_eq!(
        receipt,
        serde_json::json!({"status":"completed","input_delivered":true,"exit_code":0})
    );
    assert!(!receipt.to_string().contains("synthetic-only-correct"));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 1);
    let previews = prompts.previews.lock().unwrap();
    assert_eq!(previews.len(), 2);
    assert_eq!(previews[0], previews[1]);
    assert!(previews[0].contains(directory.0.to_str().unwrap()));
    assert!(previews[0].contains("/fixture/program"));
}
#[tokio::test]
async fn maximum_password_is_forwarded_as_one_complete_line() {
    let mut prompts = Prompts::accepting();
    prompts.value = "x".repeat(MAX_PASSWORD_BYTES);
    let (receipt, _) = execute("max-password", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Completed {
            input_delivered: true,
            exit_code: Some(0)
        }
    ));
}
#[tokio::test]
async fn even_passwordless_policy_requires_person_consent() {
    let mut prompts = Prompts::accepting();
    prompts.decision = Decision::Decline;
    let (receipt, _) = execute("no-password", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Declined {
            may_have_run: false
        }
    ));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 0);
    prompts.decision = Decision::Accept;
    let (receipt, _) = execute("no-password", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Completed {
            input_delivered: false,
            exit_code: Some(0)
        }
    ));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 0);
}
#[tokio::test]
async fn cancellation_and_expiry_never_deliver_a_password() {
    let mut prompts = Prompts::accepting();
    prompts.password = false;
    let (receipt, _) = execute("password", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(receipt, Receipt::Cancelled { may_have_run: true }));
    prompts.stall = true;
    let (receipt, _) = execute("password", &prompts, Duration::from_millis(100)).await;
    assert!(matches!(
        receipt,
        Receipt::Failed {
            reason: Failure::TimedOut,
            may_have_run: true
        }
    ));
}
#[tokio::test]
async fn wrong_nonce_never_opens_a_password_question() {
    let prompts = Prompts::accepting();
    let (receipt, _) = execute("wrong-nonce", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Failed {
            reason: Failure::ForeignHelper,
            ..
        }
    ));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 0);
}
#[tokio::test]
async fn parent_exit_withdraws_input_without_delivering() {
    let marker = Directory::new();
    let mut prompts = Prompts::accepting();
    prompts.marker = Some(marker.0.join("asked"));
    prompts.stall = true;
    let (receipt, _) = execute("parent-exits", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Completed {
            input_delivered: false,
            exit_code: Some(21)
        }
    ));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn helper_death_is_detected_even_when_sudo_is_still_alive() {
    let marker = Directory::new();
    let mut prompts = Prompts::accepting();
    prompts.marker = Some(marker.0.join("asked"));
    prompts.stall = true;
    let (receipt, _) = execute("helper-exits", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Failed {
            reason: Failure::TargetGone,
            ..
        }
    ));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn another_askpass_attempt_cannot_reuse_a_value_or_question() {
    let prompts = Prompts::accepting();
    let (receipt, _) = execute("repeat-helper", &prompts, Duration::from_secs(5)).await;
    assert!(matches!(
        receipt,
        Receipt::Completed {
            input_delivered: true,
            exit_code: Some(0)
        }
    ));
    assert_eq!(prompts.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn production_policy_rejects_the_unprivileged_fixture_before_consent() {
    let directory = Directory::new();
    let prompts = Prompts::accepting();
    let invocation = Invocation::parse(
        serde_json::json!({"target":{"kind":"sudo","argv":["/fixture/program"]}}),
    )
    .unwrap();
    let sudo = fs::canonicalize(std::env::var("AXO_TEST_SUDO").unwrap()).unwrap();
    let receipt = run_with(
        invocation,
        directory.context(),
        &prompts,
        Duration::from_secs(5),
        &sudo,
        Ownership::RootSetuid,
    )
    .await;
    assert!(matches!(
        receipt,
        Receipt::Failed {
            reason: Failure::Unavailable,
            may_have_run: false
        }
    ));
    assert!(prompts.previews.lock().unwrap().is_empty());
}
#[tokio::test]
async fn missing_installed_helper_never_asks_the_person() {
    let directory = Directory::new();
    let prompts = Prompts::accepting();
    let context = Context::new(directory.0.clone(), directory.0.join("absent-helper")).unwrap();
    let invocation = Invocation::parse(
        serde_json::json!({"target":{"kind":"sudo","argv":["/fixture/program"]}}),
    )
    .unwrap();
    let sudo = fs::canonicalize(std::env::var("AXO_TEST_SUDO").unwrap()).unwrap();
    let receipt = run_with(
        invocation,
        context,
        &prompts,
        Duration::from_secs(5),
        &sudo,
        Ownership::OwnedFixture,
    )
    .await;
    assert!(matches!(
        receipt,
        Receipt::Failed {
            reason: Failure::Unavailable,
            may_have_run: false
        }
    ));
    assert!(prompts.previews.lock().unwrap().is_empty());
}
#[tokio::test]
async fn ordinary_socket_client_cannot_claim_the_sudo_helper() {
    let channel = Channel::new().unwrap();
    let mut client = UnixStream::connect(&channel.path).await.unwrap();
    client.write_all(channel.nonce.as_bytes()).await.unwrap();
    let (server, _) = channel.listener.accept().await.unwrap();
    assert!(matches!(
        BoundHelper::bind(server, u32::MAX, &channel.nonce).await,
        Err(Failure::ForeignHelper)
    ));
}

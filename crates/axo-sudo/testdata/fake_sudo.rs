//! Nonprivileged wire fixture; never invokes the system sudo or executes its command.
use std::process::{Command, Stdio};
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    assert_eq!(&args[..3], &["-k", "-A", "--"]);
    assert_eq!(
        std::env::current_dir().unwrap(),
        std::path::PathBuf::from(args.last().unwrap())
    );
    if args.iter().any(|arg| arg == "no-password") {
        return;
    }
    if args.iter().any(|arg| arg == "wrong-nonce") {
        unsafe {
            std::env::set_var("AXO_SUDO_ASKPASS_NONCE", "0".repeat(64));
        }
    }
    let helper = std::env::var_os("SUDO_ASKPASS").expect("fixture helper");
    if matches!(args[4].as_str(), "parent-exits" | "helper-exits") {
        let mut child = Command::new(&helper)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !std::path::Path::new(&args[5]).exists() {
            if std::time::Instant::now() >= deadline {
                let _ = child.kill();
                std::process::exit(30);
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        if args[4] == "parent-exits" {
            std::process::exit(21);
        }
        child.kill().unwrap();
        child.wait().unwrap();
        std::thread::sleep(std::time::Duration::from_secs(6));
        std::process::exit(22);
    }
    let answer = Command::new(&helper)
        .arg("fixture password prompt")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .expect("start fixture helper");
    if !answer.status.success() {
        std::process::exit(11);
    }
    let mut expected = if args[4] == "max-password" {
        vec![b'x'; 255]
    } else {
        b"synthetic-only-correct".to_vec()
    };
    expected.push(b'\n');
    if answer.stdout != expected {
        std::process::exit(12);
    }
    if args[4] == "repeat-helper" {
        let second = Command::new(&helper)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .unwrap();
        if second.status.success() {
            std::process::exit(23);
        }
    }
    // Even a command that prints the synthetic secret cannot leak through this API.
    println!("synthetic-only-correct");
    eprintln!("synthetic-only-correct");
}

//! Sudo alone consumes stdout through its private askpass pipe.
fn main() {
    std::process::exit(if axo_sudo::askpass() { 0 } else { 1 });
}

/// Native row presentation, not a file-backed observation or execution lease.
/// The owner must supply activity from an exact admitted backend binding.
enum NativeAgentActivity {
    case idle
    case working
    case attention
    case detached
}

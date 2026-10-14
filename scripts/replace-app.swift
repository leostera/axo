import Darwin
import Foundation

func fail(_ message: String) -> Never {
  fputs("replace-app: \(message)\n", stderr)
  exit(1)
}

func failSystemCall(_ operation: String) -> Never {
  fail("\(operation): \(String(cString: strerror(errno)))")
}

guard CommandLine.arguments.count == 3 else {
  fputs("usage: replace-app <staged-app> <destination-app>\n", stderr)
  exit(2)
}

let staged = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
var destinationInfo = Darwin.stat()
let statResult = Darwin.lstat(destination, &destinationInfo)
let destinationExists: Bool

if statResult == 0 {
  let fileType = destinationInfo.st_mode & mode_t(S_IFMT)
  guard fileType != mode_t(S_IFLNK) else {
    fail("refusing to replace a symlinked app bundle")
  }
  guard fileType == mode_t(S_IFDIR) else {
    fail("destination exists but is not an app-bundle directory")
  }
  destinationExists = true
} else if errno == ENOENT {
  destinationExists = false
} else {
  failSystemCall("could not inspect the destination")
}

let result: Int32
if destinationExists {
  // The previous bundle remains at `staged` after the swap for rollback.
  result = renameatx_np(AT_FDCWD, staged, AT_FDCWD, destination, UInt32(RENAME_SWAP))
} else {
  // Refuse a destination created concurrently after the lstat above.
  result = renameatx_np(AT_FDCWD, staged, AT_FDCWD, destination, UInt32(RENAME_EXCL))
}

guard result == 0 else { failSystemCall("could not atomically publish Axo.app") }

// Puts the built Axo.app at dist/Axo.app (config.json's dist.mac_app), swapping it in atomically
// so a running Axo or Finder never sees a half-copied bundle (RFD0021).
//
//   install_app <built Axo.app> <destination Axo.app> <status-out>
//
// The previous bundle is kept beside it as .Axo.app.previous, for rollback. An unchanged bundle
// is left alone. It never fails the build: what happened, or why nothing did, goes to the status
// file for the build report. It never signals a running Axo or axod.
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
  fputs("usage: install_app <built-app> <destination-app> <status-out>\n", stderr)
  exit(2)
}
let built = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])
let statusURL = URL(fileURLWithPath: arguments[3])
let files = FileManager.default

func finish(_ status: String) -> Never {
  try? (status + "\n").write(to: statusURL, atomically: true, encoding: .utf8)
  exit(0)
}

func systemError(_ operation: String) -> String {
  "\(operation): \(String(cString: strerror(errno)))"
}

/// The parts of a bundle that change whenever anything in it does: its signature's resource
/// hashes, its Info.plist and its two executables.
func sameBundle(_ a: URL, _ b: URL) -> Bool {
  let parts = [
    "Contents/_CodeSignature/CodeResources",
    "Contents/Info.plist",
    "Contents/MacOS/Axo",
    "Contents/Helpers/axod",
  ]
  return parts.allSatisfy { part in
    guard let left = files.contents(atPath: a.appendingPathComponent(part).path),
      let right = files.contents(atPath: b.appendingPathComponent(part).path)
    else { return false }
    return left == right
  }
}

let name = destination.path.replacingOccurrences(of: "\(NSHomeDirectory())/", with: "~/")
var info = Darwin.stat()
var destinationExists = false
if Darwin.lstat(destination.path, &info) == 0 {
  let type = info.st_mode & mode_t(S_IFMT)
  guard type != mode_t(S_IFLNK) else { finish("\(name): not installed: it is a symlink") }
  guard type == mode_t(S_IFDIR) else { finish("\(name): not installed: it is not a directory") }
  destinationExists = true
} else if errno != ENOENT {
  finish("\(name): not installed: \(systemError("could not inspect it"))")
}

if destinationExists && sameBundle(built, destination) {
  finish("\(name): up to date")
}

let folder = destination.deletingLastPathComponent()
let staged = folder.appendingPathComponent(".Axo.app.staging")
let previous = folder.appendingPathComponent(".Axo.app.previous")
do {
  try files.createDirectory(at: folder, withIntermediateDirectories: true)
  try? files.removeItem(at: staged)
  // Bazel's outputs are read-only; the installed copy must be writable to be replaced later.
  let copy = Process()
  copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
  copy.arguments = [built.path, staged.path]
  try copy.run()
  copy.waitUntilExit()
  guard copy.terminationStatus == 0 else { finish("\(name): not installed: ditto failed") }
  let writable = Process()
  writable.executableURL = URL(fileURLWithPath: "/bin/chmod")
  writable.arguments = ["-R", "u+w", staged.path]
  try writable.run()
  writable.waitUntilExit()
  // The bundle's own dates come from the zip (1980); Finder shows when it was installed instead.
  let now = Date()
  try files.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: staged.path)
} catch {
  finish("\(name): not installed: \(error.localizedDescription)")
}

if destinationExists {
  guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0
  else { finish("\(name): not installed: \(systemError("could not swap it in"))") }
  // After the swap, `staged` holds the previous bundle.
  try? files.removeItem(at: previous)
  try? files.moveItem(at: staged, to: previous)
} else {
  guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0
  else { finish("\(name): not installed: \(systemError("could not move it in"))") }
}
finish("\(name): installed")

import Cocoa
let pid = Int32(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0")!
let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in all where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
  print("layer=\(w[kCGWindowLayer as String] ?? "?") onscreen=\(on) x=\(b["X"] ?? "?") y=\(b["Y"] ?? "?") w=\(b["Width"] ?? "?") h=\(b["Height"] ?? "?") name=\(w[kCGWindowName as String] ?? "")")
}

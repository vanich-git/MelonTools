# Local AI relay hardening — audit 4.2.1 (M1, M2, M3, M5, M6)

Status: PASS (REVIEW complete)
Baseline: `b8556ff` (working tree already carries unrelated modifications; only the two
listed files below are touched by this task).
Cumulative repairs: 0.

## SPEC

Scope: `MacOS/app/MelonTools/LocalAI/SystemPromptProxy.swift` (M1, M2, M3, M5) and
`MacOS/app/MelonTools/LocalAI/LocalHardwareService.swift` (M6 only). No project file,
dependency, or test changes; no commit.

- **M1 — connection cap.** Bucket handlers behind a locked counter (`maxConnections = 32`).
  Accept, then when full: write the fixed `503 Service Unavailable`, `Connection: close`,
  `Content-Length: 0`, close — without constructing a `Reader`, reading the request, or
  allocating request buffers. Every reserved slot is released in `handle`'s `defer`.
- **M2 — upstream timeouts + response head cap.** Apply `SO_RCVTIMEO`/`SO_SNDTIMEO` (600 s,
  unchanged) to both client and upstream sockets via one `setsockopt` helper. Relay the
  response head with `takeHead(limit: maxHead)`; on `.tooLarge` log and answer `502`,
  on `.closed` close. Request-head path untouched.
- **M3 — copies and registry reread.** The relay path parses the body once from `[UInt8]`
  (`Data(bytesNoCopy:)` inside `withUnsafeBytes`), reuses the parsed object for the model
  lookup and the prompt merge, and returns `[UInt8]`. The test-facing `merge(...body: Data)`
  overload stays for source compatibility (tests call it). The registry is cached per
  instance behind its own lock, keyed by `(URL, mtime, size)`; a changed file invalidates the
  snapshot, so prompts still update immediately when settings are saved.
- **M5 — start race.** `start()` performs the "already running" check, `bindEphemeral()`,
  `getsockname`, and the `listenFD`/`boundPort` assignment inside one critical section;
  a racing second call returns the port the first one bound.
- **M6 — formatter reuse.** One shared, configured `ByteCountFormatter` instead of a new
  instance per call; output unchanged. Declared `nonisolated(unsafe)` because the enclosing
  `@MainActor` class would otherwise make it actor-isolated and the call site is
  `nonisolated` (Swift 6 would reject it).

Out of scope: M4 (gateway YAML), `stop()`/`start()` generation ordering, Windows relay.

## Assumptions

- `merge(prompt:path:body: Data)` and `modelId(in:)` remain because the test target compiles
  against them; the request path no longer calls them.
- `Content-Length: 0` is part of "empty body" (valid, explicit framing), and the refusal
  bytes are a `static let` so a flood allocates no per-connection buffers.
- Registry mtime on APFS has sub-second resolution; `(mtime, size)` distinguishes rewrites,
  and the URL is part of the key so test overrides never return another root's prompts.

## Checks (required)

1. `swiftc -typecheck -swift-version 5` on `SystemPromptProxy.swift` + `LocalPaths.swift`
   (+ stub harness main) — compiles without errors; also `-swift-version 6
   -strict-concurrency=minimal` for the changed formatter snippet.
2. Standalone socket harness in `/tmp` (not in the repo):
   - 33 simultaneous idle connections → the 33rd receives the bare 503 (empty body,
     `Connection: close`), and a slot frees after a client disconnects;
   - oversized upstream response head (no terminator, > 64 KiB) → client receives `502`
     and the handler exits (no unbounded buffering);
   - registry prompt A → body injected; rewrite registry to prompt B → next POST carries B
     (mtime invalidation), while unchanged file reuses the cache;
   - 8 concurrent `start()` calls → one non-zero port, exactly one listening socket.
3. `swiftc -parse` on `LocalHardwareService.swift`; extracted `byteFormatter` +
   `formatBytes` compiled in a `@MainActor` stub and compared against the old per-call
   formatter on sample byte counts.
4. Manual diff review against the audit findings and the "do not break request head" rule.

## EVIDENCE

Build (no `xcodebuild`, no project-file changes):

1. `swiftc -typecheck -swift-version 5 LocalAI/SystemPromptProxy.swift LocalAI/LocalPaths.swift`
   → exit 0, no output.
2. `swiftc -typecheck -swift-version 6 -strict-concurrency=minimal` on the proxy + a
   `LocalPaths` stub (the real file's pre-existing `_baseOverride` global is the only
   Swift-6 error in the checkout) → exit 0, no warnings.
3. `swiftc -parse LocalAI/LocalHardwareService.swift` → `PARSE_OK`.
4. `swiftc -swift-version 5 LocalAI/SystemPromptProxy.swift LocalAI/LocalPaths.swift
   /tmp/proxyharness/main.swift` → exit 0; the harness links the real relay source, not a
   copy.
5. Extracted formatter (`sed -n '533,546p' LocalHardwareService.swift`) compiled inside a
   `@MainActor final class` in both `-swift-version 5` and `-swift-version 6` modes → exit 0,
   `ACTOR FORMATTER PASS` in both.

Runtime harness (`/tmp/proxyharness/harness`, 25 checks, exit 0, `HARNESS PASS`):

- 32 idle partial-head connections plus a 33rd → `HTTP/1.1 503 Service Unavailable`,
  `Content-Length: 0`, `Connection: close`, zero body bytes; closing one idle client frees
  its slot and the next request is served; after close, a full request gets 200.
- Fake upstream answers 80 KiB of header lines without the blank line → client receives
  `502 Bad Gateway` with the oversized-head message, then a normal request still gets 200.
- Registry prompt `ALPHA` → injected at `messages[0]`; unchanged file served twice from the
  cache; file rewritten to `BETA-LONGER` → next POST carries `BETA-LONGER`; `local/m1`
  alias resolves; `/v1/responses` gets `instructions`; a 2 MB body round-trips intact.
- 8 concurrent `start()` calls all return one port (`[61411 × 8]`); `lsof -nP -p <pid>
  -a -iTCP:<port> -sTCP:LISTEN` lists exactly one listener, and the relay still serves.
- `merge(prompt:path:body: Data)` regression checks: insert, blank-prompt nil, prepend to an
  existing system message, `instructions` fill.

Formatter equivalence (`/tmp/formatter/probe`): 13 values (0 … `Int64.max`) × 3 runs
compared with the old per-call `ByteCountFormatter` → `FORMATTER PASS`, zero mismatches.

Unchanged files: `LocalPaths.swift` SHA-256 `9df02aaf…` and `LocalAITests.swift`
`f89e6225…` equal their pre-change values. Post-change hashes:
`SystemPromptProxy.swift` `28ee91df…`, `LocalHardwareService.swift` `e83e3126…`.

Not runtime-tested: the 600 s socket timeout (waiting it out is outside the budget); the
constant and both `setsockopt` call sites are covered by inspection and by the fact that
normal short requests still complete.

## REVIEW

Diff reread against audit 4.2.1 after the harness run; no repair was needed.

- M1: counter is mutated only under `lock`; reservation happens in `acceptLoop` before any
  `Reader` exists, release is the first statement of `handle`'s `defer`; the refusal is a
  pre-built byte array, so an over-cap flood allocates nothing per connection.
- M2: timeouts cover client and upstream sockets through one helper; response head now goes
  through `takeHead(limit: maxHead)`, and `.tooLarge` is answered before anything is written
  to the client, so the 502 is well framed; request-head parsing is untouched.
- M3: `rewrittenBody` parses once from `[UInt8]`, reuses the parsed object for model id and
  merge, and allocates the output bytes only once; unparsable or non-rewritable bodies pass
  through as the original buffer. Cache key includes URL, mtime and size, so test roots and
  rewrites invalidate it; unreadable/corrupt registry still yields `nil` (same behavior).
- M5: bind, `getsockname` and state assignment are one critical section; the early return
  cannot observe a half-initialized listener.
- M6: formatter is configured once and only read afterwards; output equality is measured,
  not assumed.

Reviewer isolation: no separate reviewer agent was available at this delegation depth
(`subagent`/depth 0), so REVIEW was a self-review supported by the standalone harness that
compiles the real sources and exercises them over loopback sockets; tests and project files
were not modified.

## LOOP

- Repairs: 0
- Findings: —

# Release performance evidence

Measurements use original public fixtures on Apple M3 (Mac15,3), 8 logical CPUs,
16 GiB RAM, macOS 27.2 (26B123). The optimized Universal Release app is copied
from the unsigned archive and ad-hoc signed with development entitlements for
local sandboxed execution. Only arm64 executes on this host. No compiler/test
process runs during the measurements. These are engineering observations, not
M1 or Intel benchmark claims.

## Definitions and reproducibility

- `scripts/measure-app-startup.py`: a fresh app process for each sample. OS file
  and framework caches are not purged. Command-to-layout includes LaunchServices;
  app-init-to-layout excludes pre-main work. The endpoint requires a visible
  mounted native text view at its settled reading width. Compositor presentation
  and asynchronous local-image completion are excluded.
- `scripts/measure-document-work.py`: open an original fixture in an existing
  process, or append harmless comments to a disposable generated copy. The
  trigger-to-layout interval includes the native file watcher debounce for writes.
  The internal session interval begins after the watcher delivers its callback.
- `scripts/measure-running-app.py`: 30 one-second samples; accumulated process CPU
  delta divided by elapsed wall time, expressed as a percentage of one core. RSS
  sums can count shared pages twice and can fall when memory is compressed.
  `scripts/process-memory.c` supplies kernel physical footprint and lifetime peak
  via `proc_pid_rusage`, which better represents app memory cost. Surviving
  descendants are included; updater services are inactive without a configured feed.
- Core parse/tokenization runs are separate from app opening/layout. Their results
  must not be presented as UI latency or app memory.

Build the optional numeric memory helper with:

```sh
xcrun clang -Wall -Wextra -Werror scripts/process-memory.c -o build/process-memory
```

Opt-in app tracing (`-MarkUpMeasure YES`) writes only operation names, durations
and character counts. It never logs document contents, private paths or marks.
Generated stress and warm/reload copies live in ignored `Fixtures/generated/`.
All raw local measurements live in ignored `artifacts/`.

## Baseline and profiling decisions

The baseline used Turkish controls and Light appearance; final measurements use English and System appearance with automatic code-theme pairing. Since UI language/appearance and process/cache history differ, before/after values are observations, not an isolated causal benchmark of the optimization.

The first mount-aware Release baseline (before no-op layout optimization) took
3,590.823 / 1,651.912 / 1,342.270 ms from launch command to mounted layout for the
145,664-byte, 2,500-line fixture. Its median met the approximate 2-second target,
but its first sample did not. That first sample is retained, not discarded.
Of the first-versus-second sample difference, approximately 1,673 ms occurred
before `ReaderSession.reload` began; this cost remains unattributed rather than
being assumed to be filesystem caching. Session opening itself took
1,314.554 / 1,048.848 / 931.815 ms.

Code inspection then found unnecessary full native layouts: empty annotation
resolution published another revision, and no-op/denied image loading copied and
republished unchanged attributed text. Those paths now avoid publication unless
visible annotation or attachment state changes. Clearing previously painted or
unresolved marks still publishes immediately. Focused regression cases cover both
no-op identity preservation and clearing. Independent review approved the bounds.

A baseline warm process open took 852.664 ms from LaunchServices command but
136.084 ms inside the reader session. Report both intervals; the narrower timer
alone does not establish the end-to-end 500 ms target.

Baseline idle samples were 0.191% CPU / 103.00 MiB physical footprint with minimap
on, and 0.160% / 112.14 MiB with it off. Lifetime peak was 184.27 MiB. These preceded
the final command/export/performance fixes. A separate sample that overlapped a
compiler run was discarded and is explicitly marked invalid in its JSON.

## Core pipeline

Three Release samples each (`artifacts/core-performance.json`):

| Fixture | Bytes | Parse + tokenization, ms |
| --- | ---: | --- |
| 2,500 lines | 145,664 | 135.62 / 90.49 / 88.86 |
| 10,000 lines | 683,343 | 124.77 / 123.77 / 124.11 |
| 50,000 lines | 3,461,342 | 663.91 / 637.62 / 630.22 |

The representative fixture has 96 headings, 90 code blocks, roughly 35 tables and
13 local-image references. Cumulative core-test process peak RSS was approximately
144 MiB; it includes all fixture runs and is not the app's footprint.

## Profile-guided corrections

A native sample during representative reload (`artifacts/reload-profile.txt`)
captured 2,524 main-thread samples: 984 included document fitting, 710 included
TextKit layout, 217 included nested geometry updates, and 478 included native
rendering (108 included font registry lookup). These are inclusive stack counts,
not additive percentages. The coordinator now skips intermediate geometry scans
during content replacement, and each renderer pass caches complete immutable font
requests. Cache invalidation and typography changes have regressions. Full native
layout remains the dominant measured cost; incremental layout is future work.

Repeated actual window close exposed retained native text graphs and premature
reading-position restoration. The native close boundary now releases the graph,
and restoration is deferred beyond mounting. A subsequent `heap --noContent`
snapshot showed only one active ReaderTextView, but five 3,392-KiB source strings
remained in closed SwiftUI document boxes. `MarkdownFile` is now validation-only;
it retains no decoded source. File-backed sessions already use the scoped loader.
These fixes preserve content and selection rather than reducing fixture work.

## Earlier measured misses retained as evidence

The post-lifecycle, pre-payload build (`build-release-lifecycle-final.log`) measured
three cold command-to-layout samples of 1,285.090 / 1,302.920 / 1,336.149 ms. Warm
opens were 1,104.175 / 878.978 / 1,081.948 ms; settled file changes were 637.399 /
655.292 / 632.425 ms including debounce. The 500-ms warm/reload targets were missed
after the above improvements; narrower session timing must not hide that result.
Raw copies are retained under `artifacts/pre-payload-*.json`.

A first post-close idle interval measured 1.573% CPU / 137.11 MiB footprint. Minimap
off measured 0.065% / 139.86 MiB. Later unchanged minimap-on intervals after stress
were 0.129% and 0.097%. A first post-stress interval was 1.737%; it remains evidence,
not an excluded outlier. An earlier five-second native sample captured all 4,345
main-thread samples waiting for events and did not identify a persistent layout
loop. The cause of the short higher intervals is unproven.

Before native lifecycle fixes, three 50,000-line closes retained 423.46 MiB with
roughly 80 MiB added per cycle. After graph cleanup, but before payload removal,
five cycles ended at 383.50 MiB with a 460.72-MiB lifetime peak; the final settled
cycles still added about 10 MiB each. Heap evidence justified removing the retained
source copy. These values are historical, not the final payload-fixed result.

## Final payload-fixed Release

Archive log: `build-release-payload-final.log`; archive:
`build/MarkUp-unsigned.xcarchive`. Six Mach-O binaries contain arm64 and x86_64.
The local ad-hoc review app occupies 7,756 KiB (7.57 MiB), excluding dSYMs.

| Fresh process sample | Command to mounted layout | App init to layout | Reader session to layout |
| --- | ---: | ---: | ---: |
| 1 | 2108.106 ms | 1711.522 ms | 432.671 ms |
| 2 | 1409.959 ms | 1290.164 ms | 397.150 ms |
| 3 | 1317.721 ms | 1202.948 ms | 393.272 ms |

Median command-to-layout is 1,409.959 ms. The first sample exceeds 2 seconds by
108.106 ms and is retained. The final warm-open check was 1,084.887 ms (one sample;
413.429 ms inside the session). Three final reloads were 625.519 / 637.921 /
652.064 ms including debounce. The generated copy began at 145,817 bytes because
earlier harmless reload comments remain; the original 145,664-byte fixture is
unchanged. These warm/reload targets remain measured V1 performance exceptions.

Five final 50,000-line opens (3,461,342 bytes) took 4,837.449 / 4,744.203 /
4,743.291 / 4,789.856 / 4,692.453 ms command-to-layout. Every reopen preserved the
end-of-document position and minimap 99% in actual native UI. Post-close physical
footprints were 206.95 / 331.02 / 336.88 / 154.47 / 155.89 MiB. The Mac locked while
cycle four was open; after the owner unlocked it, the final two closes completed.
That longer gap allowed settling, so these are not equally spaced samples or an
isolated causal benchmark. They demonstrate recovery and near-stability in the
last two closes, not a guarantee about arbitrarily long sessions.

A subsequent 30-sample interval lasted 48.787 seconds and measured 3.976% CPU,
164.69 MiB final footprint and 458.47 MiB lifetime peak. It includes post-close
cleanup after the unlock; the cause of its higher CPU and sampling duration is
unproven. It is retained as `final-stress-idle.json`. The later settled interval
is recorded separately below.

The final `heap --noContent --sortBySize` snapshot has seven retained SwiftUI
document boxes, one ReaderTextView, no 3,392-KiB source-copy bucket, and 1,020,880
bytes of Swift.StringStorage (previous snapshot: 19,674,560 bytes). This verifies
removal of the known source retention and native graphs even when framework
window/document objects remain alive. It does not establish a universal bound on
framework caches. Raw evidence: `heap-final-closed.txt`, `final-memory-closed-*.json`,
`final-stress-cycle-*.json`, `lifecycle-ui-observations.json`.

The 10,000-line open measured 1,696.846 ms before the payload-only fix; the earlier
50,000-line single-code-block fixture (2,038,933 bytes) opened in 1,730.805 ms before
the font-cache/lifecycle fixes and its final marker was inspected. Those are
historical stress checks, not final-binary timings. The final native suite also
checks long-code end-position restoration and graph release.

## Final idle result and remaining limits

`final-settled-idle-minimap-on.json` records 30 samples over 43.095 seconds: **4.200%
CPU**, 160.95 MiB final physical footprint, 132.28 MiB RSS and 458.47 MiB lifetime
physical peak. This repeated interval misses the <1% target and must not be
described as merely transient or a passing idle gate. The minimap-off comparison
above preceded the validation-only payload change; it is not a same-session
controlled A/B benchmark of the final binary.

A final five-second native sample (`final-idle-profile.txt`) captured 3,217 main
thread samples, with 3,147 in the event-wait `mach_msg2_trap` stack. Worker threads
mostly waited for work; sparse activity included native accessibility, layout,
RunningBoard and LaunchServices. No continuous custom reader/minimap render loop
was identified. The observed CPU remains unexplained; the sample is evidence
against a demonstrated hot application loop, not proof of zero CPU cost or a
reason to discard the measured miss. A controlled independent idle benchmark on
a quiet machine is a remaining performance follow-up.

The installed-size target is met. Representative/settled memory recovered below
200 MiB; stress transient peaks substantially exceed it. Cold startup is near the
approximate target with one slightly slower final sample. Warm opening, file
refresh and the final idle CPU target are not met. These are measured exceptions
after profiling and targeted improvements; no feature, source content, annotation
safety or validation assertion was dropped to improve numbers.

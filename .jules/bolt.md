
## 2025-05-18 - Avoid Sequential Network Blocking
**Learning:** Using Python's `threading.Thread` allows replacing sequential network requests (like DNS lookups and external GeoIP APIs) with concurrent execution. This is extremely effective in avoiding the blocking behavior in single-threaded scripts triggered by external systems like Fail2Ban.
**Action:** Always inspect I/O operations (HTTP requests, DNS lookups) executed sequentially in shell/Python scripts, and use threading to perform them concurrently to reduce execution latency.

## $(date -I) - Concurrent execution in Bash with background processes
**Learning:** Bash scripts can emulate the concurrent execution seen in Python (e.g., threading/ThreadPoolExecutor) by spawning tasks as background processes (`&`) and using `wait`. This is critical when invoking sequential network requests, as it reduces execution time significantly.
**Action:** Replace slow, sequentially executed synchronous commands in Bash scripts with parallel background execution, writing outputs to temporary files (`mktemp`), and synchronize with `wait`. Ensure to clean up the temporary files afterwards.

## 2024-05-24 - Concurrent DNS Lookups in Fail2Ban Scripts
**Learning:** `concurrent.futures.ThreadPoolExecutor` registers an `atexit` handler that automatically joins all non-daemon threads, which means short-lived scripts can hang on exit if there are slow or blocked tasks (e.g. slow DNS queries).
**Action:** When implementing concurrent, short-circuiting network lookups in short-lived Python scripts, prefer `threading.Thread(daemon=True)` instead of `ThreadPoolExecutor` to ensure the process exits cleanly without blocking on abandoned tasks.
## 2024-10-27 - Batch stat calls in Bash scripts
**Learning:** Calling `stat` multiple times per file in a loop for log rotation or meta copying adds significant overhead due to process creation in Bash.
**Action:** Consolidate multiple `stat -c` calls into a single call format string (e.g. `stat -c '%Y %s'`) and parse the output, halving the process creation overhead.

## 2025-05-18 - Early return before expensive I/O operations
**Learning:** If a function performs expensive I/O (like a DNS lookup) to compare its result against a filter list, and that list can be empty, the I/O operation acts as a severe, unnecessary bottleneck. In single-threaded synchronous contexts like Fail2ban's action queue, this blocks the entire service.
**Action:** Always check if filter lists (like allowed hosts/domains) are empty and short-circuit (early return) *before* invoking any expensive operations (e.g., DNS resolution or external API calls).

## 2025-05-18 - Pure Bash configuration parsing
**Learning:** Using external binaries in a pipeline (e.g., `grep | tail | cut | tr`) for configuration parsing inside a loop or frequently called function spawns multiple sub-processes, resulting in a measurable performance overhead.
**Action:** Replace shell pipelines with pure Bash implementations using `while IFS= read -r line` and string manipulations (`${var#*=}`, `${var//[[:space:]]/}`) for simple key-value extractions. This eliminates process creation overhead and significantly accelerates execution.

## 2025-05-18 - Pure Bash String Replacement
**Learning:** Using external binaries in a pipeline like `echo | sed` inside bash functions spawns multiple sub-processes, resulting in a measurable performance overhead, especially if called multiple times.
**Action:** Replace `sed` based string replacements with pure Bash parameter expansions (`${var//search/replace}`) to eliminate process creation overhead and significantly accelerate execution.

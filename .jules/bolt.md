
## 2025-05-18 - Avoid Sequential Network Blocking
**Learning:** Using Python's `threading.Thread` allows replacing sequential network requests (like DNS lookups and external GeoIP APIs) with concurrent execution. This is extremely effective in avoiding the blocking behavior in single-threaded scripts triggered by external systems like Fail2Ban.
**Action:** Always inspect I/O operations (HTTP requests, DNS lookups) executed sequentially in shell/Python scripts, and use threading to perform them concurrently to reduce execution latency.

## $(date -I) - Concurrent execution in Bash with background processes
**Learning:** Bash scripts can emulate the concurrent execution seen in Python (e.g., threading/ThreadPoolExecutor) by spawning tasks as background processes (`&`) and using `wait`. This is critical when invoking sequential network requests, as it reduces execution time significantly.
**Action:** Replace slow, sequentially executed synchronous commands in Bash scripts with parallel background execution, writing outputs to temporary files (`mktemp`), and synchronize with `wait`. Ensure to clean up the temporary files afterwards.

## 2024-05-24 - Concurrent DNS Lookups in Fail2Ban Scripts
**Learning:** `concurrent.futures.ThreadPoolExecutor` registers an `atexit` handler that automatically joins all non-daemon threads, which means short-lived scripts can hang on exit if there are slow or blocked tasks (e.g. slow DNS queries).
**Action:** When implementing concurrent, short-circuiting network lookups in short-lived Python scripts, prefer `threading.Thread(daemon=True)` instead of `ThreadPoolExecutor` to ensure the process exits cleanly without blocking on abandoned tasks.

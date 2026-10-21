
## 2025-05-18 - Avoid Sequential Network Blocking
**Learning:** Using Python's `threading.Thread` allows replacing sequential network requests (like DNS lookups and external GeoIP APIs) with concurrent execution. This is extremely effective in avoiding the blocking behavior in single-threaded scripts triggered by external systems like Fail2Ban.
**Action:** Always inspect I/O operations (HTTP requests, DNS lookups) executed sequentially in shell/Python scripts, and use threading to perform them concurrently to reduce execution latency.

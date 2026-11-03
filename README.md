### v0.8.0
- Merge PR #24: Bolt: Replace sub-process pipeline with sed in expected_secret_keys (performance)
- Merge PR #25: Sentinel: Validate IP before geo lookup to prevent SSRF/injection (security)
- Merge PR #26: Sentinel: Guard IPv4 octet validation against IPv6 and non-numeric input (security)
- Merge PR #27: Fix: skip octet validation for IPv6 addresses (security)
- Merge PR #28: Sentinel: Harden IP octet validation against leading zeros and octal interpretation (security)
- Merge PR #29: Forge: Add strict error handling with set -euo pipefail to log_rotate.sh (robustness)
- Merge PR #30: Sentinel: Fix Telegram HTTP status check to use exact code, not substring match (security)

### v0.7.0
- Merge PR #23: Validate IP octet range in fail2ban-telegram (security/sanity)
- Merge PR #22: Add IPv4/IPv6 validation via ipaddress module (security)
- Merge PR #21: Warn about insecure secrets file permissions and cleanup temp files (security)
- Merge PR #19: Bolt: Optimize bash file reading (performance)
- Merge PR #18: IP octet validation (security)
- Merge PR #17: Max age validation (validation)
- Bump VERSION to 0.7.0
- Update changelog with new entry
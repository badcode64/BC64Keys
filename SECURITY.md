# Security Policy

## Overview

BC64Keys is a keyboard remapping utility that requires **Accessibility permissions** to function. This means the app has the technical capability to observe keystrokes system-wide.

**We take security extremely seriously.**

### Our Security Commitments

- ✅ **100% Open Source** — The entire codebase is public and auditable (GPL-3.0)
- ✅ **Single-file design** — The core app is ~2,100 lines in one file for easy security review
- ✅ **No network access** — BC64Keys works completely offline
- ✅ **No data collection** — Your keystrokes are never logged, stored, or transmitted
- ✅ **No external dependencies** — Pure Swift/SwiftUI, no third-party libraries
- ✅ **Apple Notarized** — Verified and signed by Apple's security team
- ✅ **Secure file permissions** — Log files use 0o600 (owner-only) permissions

### What BC64Keys Does With Your Keystrokes

BC64Keys uses macOS's Accessibility API (`CGEvent` tap) to:
1. **Observe** keystrokes in real-time
2. **Transform** them according to your configured mappings
3. **Forward** the modified events to the system

**Keystrokes are processed in-memory only and are never stored.**

You can verify this yourself by reviewing [`Sources/BC64Keys/BC64KeysApp.swift`](Sources/BC64Keys/BC64KeysApp.swift).

---

## Reporting a Security Vulnerability

**Please DO NOT report security vulnerabilities through public GitHub issues.**

If you discover a security vulnerability, please report it privately:

### Preferred Method: GitHub Security Advisories

1. Go to the [Security Advisories](https://github.com/badcode64/BC64Keys/security/advisories) page
2. Click **"Report a vulnerability"**
3. Fill out the form with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### Alternative Method: Direct Email

If you prefer email, you can reach out to:

**Email:** [GitHub username]@users.noreply.github.com  
**Subject:** `[SECURITY] BC64Keys Vulnerability Report`

Please include:
- A clear description of the issue
- Steps to reproduce the vulnerability
- macOS version and BC64Keys version affected
- Any proof-of-concept code (if applicable)

---

## Response Timeline

- **Initial Response:** Within 48 hours
- **Status Update:** Within 7 days
- **Fix Timeline:** Depends on severity
  - **Critical:** Immediate (hours to days)
  - **High:** Within 2 weeks
  - **Medium/Low:** Next regular release

---

## Security Best Practices for Users

### ✅ Verify App Authenticity

Always download BC64Keys from:
- ✅ **Official GitHub Releases:** https://github.com/badcode64/BC64Keys/releases
- ❌ **NOT from third-party sites**

### ✅ Check Code Signature

After downloading, verify the app is signed:

```bash
codesign -vv --deep --strict /Applications/BC64Keys.app
```

Expected output should include:
```
Signed Time: [timestamp]
Authority=Developer ID Application: [Developer Name]
...
satisfies its Designated Requirement
```

### ✅ Review Source Code

Before trusting any keyboard monitoring app:
1. Read the source code: [`BC64KeysApp.swift`](Sources/BC64Keys/BC64KeysApp.swift)
2. Build from source yourself using `./build.sh`
3. Compare checksums with official releases

### ✅ Monitor App Behavior

- Check network activity: BC64Keys should have **ZERO** network connections
- Monitor file system: BC64Keys only writes to:
  - `~/Library/Application Support/BC64Keys/mappings.json` (your settings)
  - `~/Library/Logs/BC64Keys/bc64keys-status.log` (debug logs)

---

## Scope

### In Scope

- ✅ Keystroke logging vulnerabilities
- ✅ Unauthorized file access
- ✅ Privilege escalation
- ✅ Code injection vulnerabilities
- ✅ Memory corruption issues

### Out of Scope

- ❌ Accessibility API design (macOS system limitation)
- ❌ Social engineering attacks
- ❌ Physical access attacks
- ❌ Issues in dependencies we don't control (macOS itself)

---

## Version Support

| Version | Supported          |
| ------- | ------------------ |
| 1.6.x   | ✅ Yes             |
| 1.5.x   | ✅ Yes             |
| < 1.5   | ❌ No (upgrade)    |

We provide security updates for the **current and previous major version** only.

---

## Acknowledgments

We appreciate responsible disclosure. Security researchers who report valid vulnerabilities will be:

- 🏆 Credited in the release notes (if desired)
- 📢 Acknowledged in this file
- 🙏 Thanked personally

---

## Additional Resources

- [Apple's Hardened Runtime Documentation](https://developer.apple.com/documentation/security/hardened_runtime)
- [macOS Accessibility API Guidelines](https://developer.apple.com/documentation/accessibility)
- [GPL-3.0 License](LICENSE)

---

**Last Updated:** 2026-01-31  
**Contact:** badcode64 (GitHub)

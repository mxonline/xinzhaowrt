# Arthur Source Lock

## Purpose

The source lock makes firmware builds reproducible and prevents an upstream/feed/plugin update from being mixed into an unrelated repair.

Authoritative machine-readable lock:

`config/arthur-known-good.lock`

Current Stable lock SHA256:

`1f38f596607346d12097b89f5ab92341172ffbe7a6424c22231b212efbbcc3c1`

## Locked source families

The current lock pins 14 exact Git commits:

- ImmortalWrt core
- packages feed
- LuCI feed
- routing feed
- telephony feed
- video feed
- kenzok8 package source
- iStore source
- DiskMan source
- EasyTier source
- MosDNS source
- v2ray geodata source
- OpenClash source
- OpenAppFilter source

Agents must read the actual lock file for the exact SHAs. Do not duplicate/edit SHA values in multiple documentation files as a substitute for the lock.

## Current core pin

- ImmortalWrt: `27e26e324bee0b0c2a4eb58e2e9121fea5d43194`

All other exact refs are defined in `config/arthur-known-good.lock`.

## Update policy

### Rebuild Known-Good

Use the lock unchanged. A rebuild with `rebuild_known_good` must produce no source-lock delta.

### Update ImmortalWrt

Move only the core ref unless compatibility requires a related, justified change. Record the delta and build a Candidate.

### Update feeds

Move the standard feed refs in the controlled update path. Do not silently move external plugin sources at the same time.

### Update plugins

Move only the external source family required by the request when possible. Preserve all 22 mandatory applications.

### Update all

Treat as a high-risk Candidate. Require full automated gates and real-device verification before promotion.

## Lock validation

The v3 update workflow must verify:

- lock exists;
- expected number of pinned refs exists;
- refs are exact 40-character Git SHAs;
- Candidate lock SHA256 is recorded;
- source delta is visible;
- firmware output contains the generated lock copy.

## Conflict handling

If a pinned ref disappears, becomes unreachable or no longer produces the expected package layout:

1. stop before `make defconfig` where possible;
2. classify the issue as `SOURCE`, `FEED` or `DEPENDENCY`;
3. consult `knowledge/KNOWN-FAILURES.md`;
4. repair the narrow source family;
5. create a Candidate lock;
6. never overwrite the Stable lock until promotion.

## Baseline rule

`production/known-good.json` records the Stable lock hash. `config/arthur-known-good.lock` stores the refs. A Candidate may carry a different lock, but it cannot become the new baseline until Stable promotion is complete.
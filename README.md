# BOSH release for ufw

Packages the [ufw](https://launchpad.net/ufw) firewall frontend (GPL-3, python3)
as a self-contained BOSH package + job for VM-level inbound traffic filtering
on COA BOSH deployments (replacement for the retired NSX-V vm_extension
firewalling). Rules are declared with a simple structured schema
(CIDR / port / protocol) — never raw iptables.

Intended for fleet-wide use as a **runtime-config add-on**, one add-on per
exposed protocol (e.g. `ufw-mysql` allowing 3306 from the apps subnet), scoped
with `include.jobs`. In the Orange PaaS, add-ons are wired via
`shared-operators/runtime-config/` in paas-templates — see change
`add-ufw-vm-firewall`.

## Design notes

- **Stemcell-independent**: upstream ufw is vendored (vendir) and packaged
  under `/var/vcap/packages/ufw` (canonical-path install à la Debian,
  `setup.py install --root`), never relying on stemcell-shipped ufw. The job
  invokes it through `bin/ufw` (PYTHONPATH wrapper); `bin/pre-start` seeds the
  framework files ufw expects at `/etc/ufw`, `/lib/ufw`, `/usr/share/ufw/iptables`.
- **Not a daemon**: it is a policy applier. Monit uses `check program` on
  `bin/monit_check` (active + config-hash + rule-set equality) and re-runs
  `bin/start` on drift. Reboot persistence comes from monit itself.
- **Mandatory baseline**: `ufw.allow_bosh` (SSH 22 from jumpbox/operators, node
  exporter scrape endpoint on its environment port — 9099 in this PaaS, bosh-dns
  health server 8853/tcp when health checks are enabled, and any
  other inbound management endpoint) is always rendered first; rendering *fails* when
  it is empty — no forgotten add-on property can lock operators out.
  Source convention: the environment's internal addressing supernet as a single
  constant (e.g. `192.168.0.0/16`) — monitoring scrapers are k8s-hosted with
  mutable node IPs, and a constant baseline keeps add-on files reusable across
  directors without secrets wiring.
  Egress-aware: the BOSH control plane (agent NATS session to the director,
  blobstore pulls, health monitor) is agent-initiated *outbound* traffic, so it
  needs no inbound allow and must not be listed in the baseline.
- **Ownership by comment tag**: the job only ever touches rules commented
  `paas-ufw/<instance group>`; `ufw show added` round-trip string diff keeps
  apply idempotent (add missing → enable → prune stale; no traffic window).
- **Dry-run rollout**: `enforce: false` (default) renders `config/ufw.json`,
  logs the desired rules and leaves the firewall untouched.
- **Stop semantics**: `stay_armed_on_stop: true` (default) keeps rules armed
  on stop/unmonitor/reboot; `false` runs `ufw disable` (debug escape hatch).
- **Rendering is validation**: invalid CIDR/port or a bad rule shape aborts
  the deploy before the firewall is modified.
- **IPV6 is off by default** (`ufw.ipv6: false`): BOSH stemcell/IaaS networking
  is IPv4-only. Flipping it needs a disable/enable cycle; the apply detects
  the wanted-vs-live mode change and re-toggles.
- k3s VMs must stay **excluded** from any add-on using this job (ufw's
  FORWARD/builtin-chain handling conflicts with kube-proxy; `MANAGE_BUILTINS`
  is deliberately kept `no` from upstream defaults).

## Properties

| Property | Default | Purpose |
|---|---|---|
| `ufw.rules` | `[]` | list of `{description, from: [cidr], to_ports: [port\|range], protocol: tcp\|udp\|tcp/udp}` |
| `ufw.allow_bosh` | none (required) | mandatory operational baseline, same shape as rules |
| `ufw.enforce` | `false` | dry-run vs active |
| `ufw.stay_armed_on_stop` | `true` | keep rules when the job stops |
| `ufw.logging` | `low` | ufw logging level |
| `ufw.ipv6` | `false` | manage ip6tables too (BOSH networking is IPv4-only; opt-in) |

## Usage as an add-on (recommended)

```yaml
- name: ufw-mysql
  include:
    jobs:
    - name: mysql
      release: cf-mysql
  jobs:
  - name: ufw
    release: ufw
    properties:
      ufw:
        enforce: false
        allow_bosh: ((ufw_baseline))
        rules:
        - description: mysql from apps subnet
          from: ((apps_subnet))
          to_ports: [3306]
          protocol: tcp
```

## Standalone smoke test

```
bosh upload-release # or use the dev tarball from CI artifacts
bosh deploy manifests/ufw.yml \
  -v bosh_subnet=10.0.4.0/24 -v jumpbox=10.0.4.50/32 -v apps_subnet=10.20.30.0/24
```

On the VM: `/var/vcap/jobs/ufw/bin/ufw status verbose`,
`/var/vcap/data/ufw/dry-run-rendered.json` in dry-run mode.

## Versioning

The bosh release version mirrors the upstream ufw version pinned in
`vendir.yml` (e.g. bosh release `0.36.1` == ufw `0.36.1`), like the sibling
coroot-node-agent release. Upstream has no GitHub repo: the Debian *orig*
tarball is taken from the Ubuntu source archive (content-identical to the
upstream release, stable URL, sha256-pinned). Bumps are manual — roughly one
per stemcell OS generation.

## Update flow

1. Bump url + sha256 in `vendir.yml` (manual PR, see comment in that file).
2. The `create-final-bosh-release` workflow runs `vendor.sh` (vendir sync) +
   `addblob.sh` (bosh add-blob/upload-blobs), commits `config/blobs.yml` +
   `vendir.lock`, then creates the final bosh release tagged with the upstream
   version and attaches the release tarball to the GitHub release.

Locally:

```
./vendor.sh   # downloads the pinned tarball into src/ (gitignored)
./addblob.sh  # refreshes config/blobs.yml (+ blobs/ when no blobstore creds)
bosh create-release --name ufw --version 0.0.0-dev+local \
  --tarball ./ufw-dev.tgz --force
```

`vendor.sh` + `addblob.sh` are only needed on a fresh clone or after an
upstream bump: if `bosh blobs` already lists both `ufw/ufw.orig.tar.gz` and
`ufw/setuptools-<version>-py3-none-any.whl` as `(local)`, go straight to
`bosh create-release`. `vendor.sh` fetches from the
Ubuntu archive CDN (Launchpad's own file host is flaky); on proxied runners
verify `curl -sI https://archive.ubuntu.com/ubuntu/pool/main/u/ufw/` first.

### Blob path convention (two blobs, one package)

Every vendored input must be registered with `addblob.sh` under a key prefixed
with its package name (`ufw/<file>`), listed in `packages/ufw/spec` with that
*same* key, and read in `packaging` from `${BOSH_COMPILE_TARGET}/ufw/<file>`:
BOSH materializes each `config/blobs.yml` key at `$BOSH_COMPILE_TARGET/<key>`,
and package `spec.files` entries must match the key exactly. A `../`-escaping
pattern (e.g. `../setuptools/wheel/x.whl`) never matches a blob — blobs are
keyed from the release root, not from the package directory — and fails
`bosh create-release` with `Missing files for pattern ...`. Currently packaged:
`ufw/ufw.orig.tar.gz` (upstream source) and
`ufw/setuptools-79.0.1-py3-none-any.whl` (isolated compile env, see
`packages/ufw/packaging`).

## Blobstore bootstrap (TODO)

Final releases require the s3-compat GCS bucket `orange-ufw-boshrelease` and
the `AWS_BOSH_ACCES_KEY_ID` / `AWS_BOSH_SECRET_ACCES_KEY` repo secrets (same
pattern as orange-k3s-wrapper-boshrelease). Until then only dev releases work.

## Upstream provenance

| | |
|---|---|
| Upstream | https://launchpad.net/ufw |
| Current pin | ufw 0.36.1 (`ufw_0.36.1.orig.tar.gz` via Ubuntu source archive), sha256 in `config/blobs.yml` and `vendir.lock` |
| Upstream license | GPL-3 |

# Contributing

## Commits

All commits MUST be SSH-signed (`git config gpg.format ssh`), see the
paas-templates CONTRIBUTING guide. Conventional-commit messages (`feat:`, `fix:`, ...).

## Bumping the ufw version

1. Pick the new series page https://launchpad.net/ubuntu/<series>/+source/ufw
   and take the `*.orig.tar.gz` link + its sha256 (see comment in vendir.yml).
2. Edit `url:` and `sha256:` in `vendir.yml` (manual PR — no GitHub datasource
   for ufw, so Renovate does not watch it).
3. `./vendor.sh && ./addblob.sh` (requires devbox: vendir, bosh, yq).
4. Validate locally: `bosh create-release --name ufw --version 0.0.0-dev+<x> --tarball ./dev.tgz --force`.
5. PR and merge — CI produces the final release tagged with the upstream version.

## Never commit

- `src/` and `blobs/` (vendir/blob caches)
- `config/private.yml` (blobstore credentials)
- real CIDRs of production subnets in manifests/README (use `-v` / vars-store;
  real values belong in paas-templates vars, not here)

# CI

## Workflows

- `PR`: shell syntax check and the forge tests; on a `release/X.Y.Z` branch,
  also fails when tag `X.Y.Z` already exists.
- `Tag Release` (`tag.yml`): on a merged `release/X.Y.Z` pull request, tags
  `X.Y.Z` and dispatches `Release`.
- `Release` (`release.yml`): creates the GitHub Release, then builds and
  attaches the .deb, builds the RPM, uploads to the PPA (when enabled) and
  publishes the Homebrew formula. Runnable by hand with `release_tag` to
  backfill an existing tag.

## Required GitHub Secrets (PPA)

- `PPA_GPG_PRIVATE_KEY`: armored private key for signing the source package.
- `PPA_GPG_PASSPHRASE`: passphrase for the signing key.
- `PPA_SSH_PRIVATE_KEY`: SSH key registered with Launchpad.

## Required GitHub Variables (PPA)

- `PPA_GPG_KEY_ID`: key ID or fingerprint (non-secret).
- `PPA_PUBLISH_ENABLED`: set to `true` to enable the PPA publish job.

## Required GitHub Secrets (Homebrew)

- `HOMEBREW_TAP_DEPLOY_KEY`: private half of the tap's write deploy key.
- `HOMEBREW_TAP_REPO`: the tap, as `owner/repo`.

## PPA target

Update `ppa_target` in `.github/workflows/release.yml`:

```
ppa:your-launchpad-id/isoforge
```

## Notes

- Debian source builds use `debuild` and the `debian/` metadata in this repo.
- RPM builds use the reusable `ci-helpers` workflow with `script-helpers` RPM helpers.
- Homebrew builds use the reusable `ci-helpers` workflow and publish to the tap for every release.

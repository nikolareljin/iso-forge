# Repository rename: burn-iso to iso-forge

## Intent

The repository is being renamed from `burn-iso` to `iso-forge` so its GitHub
name, clone URL and GitHub Pages path match the existing IsoForge CLI and
package name. This is a repository and URL migration only: the `isoforge`
command and package identity remain unchanged.

## Required order

1. Finish and merge this documentation and the corresponding R-765 backlog
   item before changing the GitHub repository name.
2. Inventory every owned-repository reference to `nikolareljin/burn-iso` and
   classify it as source, package metadata, workflow, documentation, release
   URL, Pages URL or GitHub setting.
3. Rename the GitHub repository, retaining GitHub's redirect from the old URL.
4. Update the local checkout, origin remote, Pages configuration and every
   inventoried owned reference to `nikolareljin/iso-forge`.
5. Publish the site at `/iso-forge/`, verify old repository URLs redirect, and
   verify no active owned code or configuration still names `burn-iso`.

## Migration checklist

- GitHub repository name, description, homepage, topics, Pages configuration,
  release links and repository redirects.
- Local clone directory and `origin` fetch/push URL.
- README clone commands, badges, documentation, source URLs and support links.
- Debian metadata, RPM spec, Homebrew formula/generator and release tarball
  URLs.
- GitHub Actions workflow configuration, release targets and Pages links.
- References in every owned repository, including NikOS, distrodeck,
  kiosk-frame, ai-runner, ci-helpers, script-helpers, R-765, R-235 and the
  shared tool-suite navigation.

## In-repository status

Steps 1, 2 and the in-repository half of step 4 are complete as of 1.1.0: every
reference in this repository names `nikolareljin/iso-forge`, and the `isoforge`
CLI, package, Homebrew formula and man page are untouched.

Step 3, the GitHub-side rename, has not happened yet, so `nikolareljin/iso-forge`
does not resolve until it does. Step 5 and the downstream reference migration in
other repositories are still outstanding. Live progress belongs in the R-765
issue created from its backlog item; this document records the migration
contract rather than status.

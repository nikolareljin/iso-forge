Name:           isoforge
Version:        2.2.0
Release:        1%{?dist}
Summary:        TUI tool for downloading and flashing ISO images to USB
License:        MIT
URL:            https://github.com/nikolareljin/iso-forge
BuildArch:      noarch
Source0:        %{name}-%{version}.tar.gz

Requires:       bash, dialog, curl, jq, coreutils, util-linux
Recommends:     xorriso, squashfs-tools, rsync, python3dist(pyyaml)

%description
Isoforge provides a simple terminal UI for selecting and downloading distros,
flashing to USB, and creating Ventoy multi-ISO drives. It also builds custom
installable images: `isoforge build` remasters an Ubuntu or Xubuntu base image
from a recipe describing packages, settings and provisioning.

%prep
%autosetup -n %{name}-%{version}

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/isoforge
mkdir -p %{buildroot}/usr/share/isoforge/inc
mkdir -p %{buildroot}/usr/share/isoforge/scripts
mkdir -p %{buildroot}/usr/share/isoforge/recipes
mkdir -p %{buildroot}/usr/share/isoforge/assets
mkdir -p %{buildroot}/usr/share/doc/isoforge
mkdir -p %{buildroot}/usr/share/man/man1

install -m 0755 inc/isoforge.sh %{buildroot}/usr/bin/isoforge
cp -a inc/* %{buildroot}/usr/share/isoforge/inc/
install -m 0644 config.json %{buildroot}/usr/share/isoforge/config.json
install -m 0644 VERSION %{buildroot}/usr/share/isoforge/VERSION
cp -a scripts/* %{buildroot}/usr/share/isoforge/scripts/
cp -a recipes/* %{buildroot}/usr/share/isoforge/recipes/
cp -a assets/* %{buildroot}/usr/share/isoforge/assets/
install -m 0644 docs/USER-GUIDE.md %{buildroot}/usr/share/doc/isoforge/USER-GUIDE.md
install -m 0644 docs/man/isoforge.1 %{buildroot}/usr/share/man/man1/isoforge.1

%files
/usr/bin/isoforge
/usr/share/isoforge/inc
/usr/share/isoforge/config.json
/usr/share/isoforge/VERSION
/usr/share/isoforge/scripts
/usr/share/isoforge/recipes
/usr/share/isoforge/assets
/usr/share/doc/isoforge/USER-GUIDE.md
# RPM's brp-compress hook may compress the installed page to .1.gz. Keep the
# manifest valid regardless of whether that hook runs on the build host.
/usr/share/man/man1/isoforge.1*

%changelog
* Thu Sep 10 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.2.0-1
- Add Ventoy-first USB preparation and ISO Creator workflows
- Add NikOS post-install recipe, bundled backgrounds and expanded catalog
- Open authenticated catalog sources in the browser
- Replace obsolete exfat-utils and refresh generated CLI documentation

* Thu Sep 03 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.1.3-1
- Go back to a plain working directory; the rpm _topdir fix is in ci-helpers

* Thu Sep 03 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.1.2-1
- Fix the deb artifact path and the rpm _topdir so both jobs can produce packages

* Thu Sep 03 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.1.1-1
- Move vendored script-helpers from 0.9.2 to 0.24.0

* Tue Sep 01 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.1.0-1
- Add an end-to-end NikOS ISO build workflow and an artifact verifier
- Fail the build when a recipe names an Ansible tag the playbook does not define
- Correct the NikOS recipe's skip_tags, which named an untagged role

* Tue Sep 01 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.0.2-1
- Declare Source0, which %%autosetup requires
- Build the Debian package as a native source package

* Tue Sep 01 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.0.1-1
- Grant the release workflow the permissions its called workflows declare, so
  the deb, PPA, RPM and Homebrew jobs can run at all

* Tue Sep 01 2026 Nikola Reljin <nikola.reljin@gmail.com> - 2.0.0-1
- Add `isoforge build`, which remasters an Ubuntu or Xubuntu base image into a
  custom installable ISO from a recipe
- Recipes describe packages, apt sources, overlay files and chroot hooks, and
  can drive a NikOS Ansible playbook or read a distrodeck export
- Ship the example recipes and recommend xorriso, squashfs-tools and PyYAML

* Tue Sep 01 2026 Nikola Reljin <nikola.reljin@gmail.com> - 1.1.0-1
- Repoint source repository references to iso-forge; the package remains isoforge
- Fix the script-helpers path default in inc/burn.sh
- Align version metadata at 1.1.0
- Remove unreferenced inc/include.sh and inc/distros.sh

* Fri Jan 09 2026 Nikola Reljin <nikola.reljin@gmail.com> - 0.1.0-1
- Initial release

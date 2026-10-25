# CMP 170HX Unlock Driver

> **WARNING: NOT STABLE, STILL IN TESTING**
>
> This plugin is under active development and has not been fully tested on real hardware yet. Expect bugs and
> breaking changes. Do not rely on it for anything important, and keep a way to get your server back up without
> it. Reports are welcome, but please include the diagnostics file from the plugin page.

An Unraid plugin that installs a patched Nvidia driver for the **CMP 170HX**, unlocking the card's full memory
and making it usable from Docker containers. The patches come from
[cmpunlocker](https://github.com/amoghmunikote/cmpunlocker).

The plugin installs the driver that matches your running Unraid kernel at every boot, shows the unlock status on
a settings page, and tells you before an Unraid upgrade would leave the card without a driver.

## Requirements

- Unraid 7.x.
- A CMP 170HX (8 GB model `10de:20c2` or 10 GB model `10de:2082`) installed in the server.
- Internet access at boot the first time a kernel is used. After that the driver is cached on the flash drive.
- About 400 MB free on the flash drive.
- The **Nvidia Driver plugin must not be installed.** This plugin replaces it (see below).

## Install

1. Remove the Nvidia Driver plugin if you have it, and reboot.
2. In Unraid, go to *Plugins > Install Plugin* and paste:

   ```
   https://github.com/IDmedia/cmp170hx-unlock-driver/raw/main/cmp170hx-unlock-driver.plg
   ```

3. Open *Settings > Utilities > CMP 170HX Unlock Driver*.
4. **Shut the server down completely**, wait until power drops, and power it on again. A warm reboot is not
   enough: the card only finishes unlocking after a cold boot.
5. If Docker was already running when you installed, disable and re-enable it (*Settings > Docker*).

## Conflict with the Nvidia Driver plugin

Both plugins install an Nvidia driver, so only one can be installed.

- Installing this plugin while the Nvidia Driver plugin is present is refused.
- If the Nvidia Driver plugin appears later, this plugin installs nothing at boot and notifies you.

If you used the manual `cmpunraider.sh` script before: run `bash cmpunraider.sh uninstall`, remove the Nvidia
Driver plugin, reboot, then install this plugin.

## What it does at boot

1. Checks for the Nvidia Driver plugin and for a CMP 170HX on the PCI bus.
2. Uses the cached driver packages, or downloads them from this project's releases and verifies their
   checksums. The driver comes in two parts: the Nvidia userspace (libraries, firmware, container toolkit,
   ~430 MB, one per driver version) and the patched kernel modules (small, one per kernel). After an Unraid
   upgrade that keeps the driver version, only the modules are downloaded.
3. Installs both, loads the driver, optionally reloads it and retrains the PCIe link to Gen2, and sets up Docker
   (CDI and the container runtime) for the GPU.

The boot step never makes Unraid fail to start. If something goes wrong, the plugin records a state, sends a
notification and exits normally.

## Unraid updates

Each Unraid release has its own kernel, and the patched driver has to be built for that exact kernel. Builds are
published automatically once the required kernel files exist, which may be some time after an Unraid release.

- **Before you upgrade:** the settings page and a daily notification check whether the next Unraid release has a
  matching driver. Only upgrade when it shows as supported. Unraid does not let a plugin block an upgrade, so
  this is a warning only. If the check cannot find out, it says so; it never reports "supported" without proof.
- **If you upgrade anyway:** no driver is installed for the new kernel, you get a notification, and your
  settings are kept. The array and Docker start normally, but the GPU has no driver. The driver installs on a
  later boot once a build is published, or use *Re-check now* and *Download package now* on the plugin page.

## Settings

| Setting | Meaning |
|---|---|
| Nvidia driver version | `latest` or a specific version. Only versions built for your kernel are listed. |
| cmpunlocker version | `latest` or a specific cmpunlocker tag. Only built versions are listed. |
| Card profile | `Auto-detect` (recommended), 8 GB, 10 GB, or both models. A profile that contradicts the detected card is refused at boot. |
| PCIe Gen2 retrain | Reloads the driver once at boot and retrains the link to Gen2. |
| Update notifications | Once a day (8-10 am): warns about unsupported Unraid releases and downloads newer drivers when the version is `latest`. Reboot to install them. |

If the version you selected is not available for your kernel, the newest available build for your card is
installed instead and you are notified.

## Status page

*Settings > Utilities > CMP 170HX Unlock Driver* shows:

- Unraid version, kernel, and whether a patched driver exists for it.
- Detected cards, loaded driver, installed and cached package.
- Per GPU: memory (unlocked, stock or unexpected size), PCIe generation, ECC mode.
- Health checks: driver loaded, memory unlocked, the unlock marker in the kernel log, the Gen2 retrain log.
- Support status of newer Unraid releases.
- A diagnostics download for bug reports.

Expected memory once unlocked: about 65536 MiB on the 8 GB model and about 40960 MiB on the 10 GB model. An idle
card can report a lower PCIe generation than it is capable of.

## Troubleshooting

- **Memory still stock (8192 / 10240 MiB):** make sure you did a full power-off, not a warm reboot, and that the
  status page shows the patched package as installed.
- **"Kernel ... is not supported yet":** no patched driver is published for your Unraid version. Nothing is
  broken; wait for support, then reboot.
- **"Driver not installed":** the release server was unreachable at boot. Check the internet connection and reboot.
- **Gen1 instead of Gen2:** check the Gen2 retrain log on the status page, and that *PCIe Gen2 retrain* is enabled.
- **Anything else:** download the diagnostics from the plugin page and include it in your report.

## Uninstall

Remove the plugin in *Plugins*. This removes the driver packages, the cron entry, the modprobe option, the CDI
file and the plugin's settings and cache on the flash drive. Reboot afterwards: the loaded driver stays active
until then.

## How it is built

The packages are built by GitLab CI on the maintainer's GitLab and published as releases of
[IDmedia/cmp170hx-unlock-driver-packages](https://github.com/IDmedia/cmp170hx-unlock-driver-packages). That repo
holds only releases; it is separate from this one because this one is a push mirror, and a mirror removes
tags that exist only on GitHub.

| Release tag | Contents |
|---|---|
| `nvidia-<driver>` (e.g. `nvidia-615.71.09`) | `cmp170hx-nvidia-<driver>-x86_64-1.txz`: the stock [unraid-nvidia-driver](https://github.com/unraid/unraid-nvidia-driver) package of that driver version without its kernel modules. Taken from whichever kernel's release has it, so a driver stays available after Unraid stops building it for new kernels. |
| `<kernel>` (e.g. `6.18.58-Unraid`) | `cmp170hx-modules-<driver>-<cmpunlocker>-<profile>-<kernel>-1.txz`: the cmpunlocker-patched open kernel modules, plus `manifest.json` listing them, their checksums and the userspace package each needs. |

The plugin only downloads from these releases, so an outage upstream cannot break an installed system. A new
kernel needs a pre-compiled kernel tree from [ich777/unraid_kernel](https://github.com/ich777/unraid_kernel);
until that exists, the kernel stays unsupported.

### What CI builds

`versions.json` decides, and everything else is worked out by `ci/discover.sh`:

| Key | Meaning |
|---|---|
| `min_kernel` | Oldest Unraid kernel to build for. |
| `cmpunlocker` | cmpunlocker tags to build. The drivers come from each tag's `driver/VERSION`. |
| `drivers_per_tag` | How many of a tag's drivers to build (newest first). The plugin picks the newest by default; older ones are a fallback users can choose. |
| `profiles` | Card profiles to build. |

Every combination that is not in a kernel's `manifest.json` yet gets built, so adding a tag also builds it for
kernels that are already published. Nothing is ever deleted from a release by CI.

### Pipeline

- **Every push and merge request:** shellcheck, `php -l`, the off-box tests of `cmp.sh` (`tests/cmp_test.sh`,
  stubbed system commands and a local release server) and a check that the committed plugin package matches
  `source/` and the `.plg` (`tests/plugin_package_test.sh`).
- **On `main`, when `versions.json`, `ci/` or `.gitlab-ci.yml` change, on the schedule, or run by hand:**
  `discover` generates a child pipeline: `userspace:<driver>` jobs, then per kernel `build:<kernel>` (in
  ich777's build image for that kernel) and `publish:<kernel>`. A combination that fails to build does not
  hold back the others.
- **On the schedule:** `check-upstream` opens a merge request when cmpunlocker publishes a new tag. Merging it
  builds the tag for every kernel.

### Maintainer setup (once)

1. GitHub: push mirror from GitLab (*Settings > Repository > Mirroring repositories*) to
   `https://github.com/IDmedia/cmp170hx-unlock-driver.git`, the repository users install the plugin from.
2. GitHub: the public repository `IDmedia/cmp170hx-unlock-driver-packages`, initialised with a README (releases
   need a commit to tag). CI only creates releases there; nothing pushes to it.
3. GitLab CI/CD variables (masked, protected):
   - `GITHUB_TOKEN`: fine-grained GitHub token for `IDmedia/cmp170hx-unlock-driver-packages`, *Contents: read and write*.
   - `CI_PUSH_TOKEN`: project access token, role Developer, scope `write_repository` (for check-upstream).
4. GitLab pipeline schedule on `main`, e.g. every 6 hours (`17 */6 * * *`).
5. Runner: tagged `linux`, any Docker executor with ~10 GB free disk. No privileged mode, no access to the Unraid servers.

### Day to day

- Change the plugin UI or `cmp.sh`: edit under `source/`, add a `###<version>` entry to `<CHANGES>` in the
  `.plg`, run `bash source/makepkg-unraid.sh <version>` on Linux or WSL, and commit `packages/` and the `.plg`.
  CI fails if you forget.
- Rebuild one kernel: *Build > Pipelines > Run pipeline* on `main` with `FORCE_KVER=6.18.58-Unraid`.
- The packages repository name lives in two places: `GH_REPO` in `.gitlab-ci.yml` and `BASE` in `cmp.sh`.

### Manual check on a server without a CMP 170HX

Install the `.plg`, open the settings page (status, upgrade check, version lists), then set *Card profile* to
8 GB and reboot. The plugin downloads, verifies and installs both packages; `nvidia-smi` and `nvidia-ctk`
exist, and only loading the module fails, so the page reports *Driver installed but not loaded*. Remove the plugin afterwards
and reboot.

## Credits and licenses

- The unlock itself is the work of [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker) (GPL-2.0) and its
  contributors. This plugin only packages it for Unraid.
- The plugin structure derives from [unraid-nvidia-driver](https://github.com/unraid/unraid-nvidia-driver) (MIT).
- Kernel trees used by CI come from [ich777/unraid_kernel](https://github.com/ich777/unraid_kernel).

See [NOTICE](NOTICE) for details. This project is not affiliated with Unraid, Nvidia, or the upstream projects.

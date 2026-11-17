# Contributing to Radiata

Contributions to the theme, compatibility mappings, documentation, and accessibility are welcome.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large visual redesign or installer change.
- Do not submit copyrighted images, fonts, logos, or themes without a compatible license and attribution.
- Test changes on an Ubuntu GNOME system or clearly state what could not be tested.

## Development

```bash
git clone <repository-url>
cd radiata
bash -n install.sh uninstall.sh lib/common.sh
./install.sh
```

Log out and back in after GNOME Shell changes. Restore the prior desktop with `./uninstall.sh`.

## Pull requests

Keep changes focused. Describe:

- The visual or behavioral problem
- Ubuntu and GNOME versions tested
- Files and settings changed
- Installation and uninstall results
- Before/after screenshots for visual changes
- Asset source and license for every new image

By submitting a contribution, you agree to license it under the repository's MIT License unless the pull request explicitly documents a compatible asset exception.

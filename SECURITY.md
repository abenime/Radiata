# Security policy

Radiata installs user themes and also uses `sudo` for Ubuntu packages and the optional GDM login resource. Security reports deserve private handling.

## Supported versions

Security fixes are provided for the latest tagged release and the current default branch.

## Reporting a vulnerability

Use GitHub's **Security → Report a vulnerability** feature after the repository is published. If private vulnerability reporting is unavailable, contact the maintainer through the address or profile listed in `AUTHORS.md`. Do not publish an exploit or sensitive system details in a public issue.

Include:

- Radiata version or commit
- Ubuntu and GNOME versions
- The affected script or generated path
- Reproduction steps
- Expected impact
- A proposed fix, if available

## Installer trust boundary

Review `install.sh` before running it. The script invokes `sudo` only to install named Ubuntu packages and to register files under `/usr/local/share` through the `gdm-theme.gresource` alternatives group. Run the installer as the desktop user, never as root.

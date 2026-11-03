# Security Policy

`ada` is a local macOS utility. It can edit shell startup files, agent hook
configuration, and LaunchAgent state when you ask the installer to wire those
integrations. Treat those surfaces as security-sensitive.

## Reporting A Vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub private vulnerability reporting for this repository if it is enabled.
If that is not available, contact the maintainer through the repository owner's
GitHub profile and include:

- what is affected
- how to reproduce it
- whether it can leak prompts, commands, local paths, credentials, or files
- the macOS version and integration involved

## Security Expectations

- The core app should stay local-first and avoid telemetry. The update check
  (`lib/ada-update.sh`) is the one network request: an HTTPS GET of the
  public formula, once a day (hourly after a failed check), carrying no
  headers, data or identifiers of ours and nothing from the user's
  `~/.curlrc` (`curl -q`), off with `ada-update off` or
  `ADA_UPDATE_CHECK=0`. It must never run in an alert's foreground, follow a
  redirect off HTTPS, or send anything from the machine.
- Loopback helpers must bind only to `127.0.0.1` and require an unguessable
  token for control requests.
- Installers must preserve unrelated user config and write backups before
  mutating existing JSON hook files.
- LaunchAgent code must run from a non-TCC-protected staged path and should not
  require elevated privileges.
- Debug logging must remain opt-in and should avoid capturing more prompt or
  command data than needed.
- Alert labels kept on disk (the alert history and mute markers, which hold
  prompts and commands) must stay in the per-user temp dir, be created mode
  600, never be written through a symlink, and never leave the machine.

## Supported Versions

Before formal releases exist, security fixes land on the default branch.

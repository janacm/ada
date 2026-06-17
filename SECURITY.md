# Security Policy

`iyf` is a local macOS utility. It can edit shell startup files, agent hook
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

- The core app should stay local-first and avoid telemetry.
- Loopback helpers must bind only to `127.0.0.1` and require an unguessable
  token for control requests.
- Installers must preserve unrelated user config and write backups before
  mutating existing JSON hook files.
- LaunchAgent code must run from a non-TCC-protected staged path and should not
  require elevated privileges.
- Debug logging must remain opt-in and should avoid capturing more prompt or
  command data than needed.

## Supported Versions

Before formal releases exist, security fixes land on the default branch.

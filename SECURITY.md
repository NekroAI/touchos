# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub: go to the repository's **Security** tab and choose **Report a vulnerability**. Include a description, the affected version and steps to reproduce.

We aim to acknowledge reports within 3 working days and to agree on a disclosure timeline with you. We will credit you in the release notes unless you prefer otherwise.

## Scope

We are especially interested in:

- Anything that lets another process abuse TouchOS's Accessibility permission or its event tap.
- Imported panel configurations that run shell commands or scripts without the user's explicit confirmation.
- Trackpad contact data being written to disk, logs or the network.

## Supported versions

TouchOS is pre-1.0. Security fixes are released for the latest version only.

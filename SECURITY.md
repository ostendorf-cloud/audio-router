# Security Policy

## Supported versions

This project is a command line prototype and has no release yet. It has no LTS branches.
Once releases exist, only the latest release gets security fixes.

## Scope

audio-router taps the audio of other apps through Core Audio and plays it on another output device.
These areas are in scope:

- The audio tap and the aggregate device it creates, including what they expose to other processes.
- The system audio capture permission, including its usage string and any way around the permission prompt.
- Teardown: any exit path that leaves a tap or an aggregate device behind, or leaves an app muted.
- Input handling of the command line arguments, bundle identifiers and device identifiers.

Releases are signed ad hoc. They are not notarized.

## Reporting a vulnerability

The preferred channel is a draft security advisory through GitHub's private vulnerability reporting,
the "Report a vulnerability" button under this repository's Security tab, where enabled.

When private reporting is unavailable or unsuitable, report to `security@ostendorf.cloud`.
This is the contact the other repositories of the organisation use.

Do not open a public issue for a vulnerability that is not yet patched.

## What to expect

- An acknowledgement of the report.
- No public issue opened before a fix is available.
- Credit in the fix's changelog entry once resolved, if you want to be credited.

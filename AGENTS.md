# .github

The files every repository of the zaentrum organisation shares: the
[security policy](./SECURITY.md) and the [guide to contributing](./CONTRIBUTING.md).
GitHub shows them in each repository of the organisation that has no file of
its own by the same name. How a change is proposed and what a pull request has
to pass is in the guide to contributing; what may be built is in
[building from the specification](https://github.com/zaentrum/zaentrum/blob/main/AGENTS.md).

## Build

Nothing is built: the files are text.

## Test

`.github/workflows/neutrality.yml` runs on every pull request and on main: the
neutrality check's own tests (`bash neutrality/test.sh`), then the check over
this repository (`bash neutrality/check.sh`). Both run the same way locally.

## Run it

A change shows once it is merged. The security policy appears on the Security
tab of every repository without its own `SECURITY.md`. The guide appears beside
a new issue or pull request in every repository without its own
`CONTRIBUTING.md`.

## What the tests leave unchecked

Everything: no check reads these files, not even their links.

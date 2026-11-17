# Contributing to zaentrum

This guide holds for every repository of the zaentrum organisation: how a
change is proposed, what a pull request has to pass, and what never belongs in
a public repository. A security hole is not reported here: the
[security policy](https://github.com/zaentrum/.github/blob/main/SECURITY.md)
says how.

## The specification first

For anything a person sees, the specification comes first, then the code.
Every difference between what is built and the target is a numbered change in
a chapter of the [specification](https://github.com/zaentrum/zaentrum/tree/main/spec),
such as `11.C30`, with a status: proposed, approved, built, verified or
withdrawn. Only an approved change is built.

To propose a change, open a pull request to
[zaentrum/zaentrum](https://github.com/zaentrum/zaentrum) that adds it to its
chapter's Changes table as `proposed`. The owner approves it, or doesn't.
[Building from the specification](https://github.com/zaentrum/zaentrum/blob/main/AGENTS.md)
says what may be built, what a change asks for, and when it is done.

Work nobody sees, such as a test or a build step, goes straight to a pull
request in its repository.

## One change, one pull request

- Work on a branch, never on the main branch. Each change is one branch and one
  pull request, named by the change's number where it has one.
- A change to what the code does comes with a test that fails without it, with
  the change's number in its name.
- How a repository is built and tested is in the file `AGENTS.md` at its root:
  what it is, the command that builds it, the command that runs its tests, how
  it runs against the reference demo or recorded answers, and what its tests
  leave unchecked.

## What a pull request has to pass

- The repository's workflow, which builds it and runs its tests on every pull
  request. Two repositories differ:
  - zaentrum/zaentrum's one pull-request workflow, `docs-check.yml`, runs only
    when a pull request touches `docs/`, `spec/` or `scripts/`. Its `check` job
    runs `python3 scripts/check-docs.py`, `python3 scripts/check-spec.py` and
    `python3 scripts/capabilities.py --check`, and its `site` job builds the
    site from the pull request's `docs/` and `spec/`.
  - zaentrum/.github, this repository, has no workflow.
- A review by a maintainer, who then merges it.

## What zaentrum is not

zaentrum catalogs and streams a library that is already on disk. Anything that
fetches or downloads content, decides what to go and get, or reaches out to
indexers or trackers lives outside these repositories, as an addon
([scope](https://github.com/zaentrum/zaentrum/blob/main/docs/architecture.md)).
A pull request that adds it is declined.

zaentrum is neutral: it holds no server, identity provider or branding of any
one installation. The platform learns its host and its identity provider from
its `Zaentrum` resource; the apps learn theirs from the server they are given.

## What never belongs in a public repository

Not in the code, a test, a commit message, a page or a picture:

- a hostname, an address, a path or a name of a real installation;
- the name of a private person, or an e-mail address: commit under the private
  address GitHub gives you;
- a password, a token, a key, a keystore or a kubeconfig;
- the name of another media product;
- the title of a real commercial film or show. The reference demo's
  open-licensed titles are fine.

And no sentence on a screen that is not true on every installation.

## Licence

What you contribute to a repository that has a `LICENSE` file is released under
the licence in it.

# The neutrality check

One check for every repository of the zaentrum organisation. It reads every
text file a repository tracks, hidden ones included, for the names of other
media products and of download tools and, in code and configuration, for the
vocabulary of acquiring content. Its rules name nothing of any one
installation. It fails when a line breaks a rule:

- **product**: the name of another media product, anywhere, prose included.
  The project describes itself, not what it might replace.
- **tool**: the name of a download tool or one of its components, anywhere,
  prose included.
- **vocab**: the vocabulary of acquiring content, in code and configuration
  only. Prose has to be able to say what the project refuses to build.

The words are in [`rules.txt`](./rules.txt), and
[`cases.txt`](./cases.txt) holds the lines each rule must and must not flag.
These two files are the only place the words stand, and the check leaves
their directory out of its scan, as it lists what it bans. The check runs
the cases before every scan and stops with exit status 2 when one goes
wrong, so a rule that no longer catches what it should cannot pass a
repository. The log names the file, the line and the rule, never the line's
text.

## What it guarantees

On a pull request the check is no gate against the pull request's own
author, who can change the repository's workflow and its exceptions, add the
marker, or make a file read as binary. What it guarantees comes from review
and from the run on main, which reads the repository as it stands after the
merge. That every change is reviewed before it is merged is a practice of
the organisation, and nothing enforces it.

The check reads words and forms, not meaning. Two tools are named with
ordinary English words, which count only in a tool's own forms (listed
below), so prose that names either tool, in a heading, a row of a table or
with a version after the word, is not flagged. Seeing that stays with the
reviewer.

## Calling it

Add a job to the workflow that runs on your repository's pull requests and on
its main branch:

```yaml
jobs:
  neutrality:
    permissions:
      contents: read
    uses: zaentrum/.github/.github/workflows/neutrality.yml@v1
    with:
      exceptions: |
        examples/published/  the published example, as it is released
```

The job checks out your repository into `repository/`, then this
repository, at the commit the workflow file was read from, into `check/`
beside it, and runs the check over your tracked files. It needs only read
access to the repository's contents.

`v1` is a tag that a pull request cannot move: this repository's tag
ruleset blocks updating and deleting it. A change to the rules or to the
check is reviewed and merged on main like any other change. Then the
organisation's owner lifts the ruleset, moves `v1` to the reviewed commit,
and puts the ruleset back. Nothing else moves `v1`. To use a change before
that, call the workflow at the commit's full sha instead of `v1`. A full sha
runs that very commit whether it is merged or not, and the log names it the
same way either way, so the reviewer of a caller that pins one checks that
the sha is on this repository's main branch:
`gh api repos/zaentrum/.github/compare/<sha>...main --jq .status` answers
`ahead` or `identical` for a commit on main.

## How a word counts

Case does not count. A word counts only as a word of its own: a letter or a
digit next to it makes it part of a longer word, which passes, while any
other character and the ends of a line separate it. Each line of
`rules.txt` says, with its flags, what else separates its words:

- **product**: a case change too, so a name inside a camelCase or
  PascalCase identifier counts, after an acronym as well (`XMLFooParser`
  reads as `XML Foo Parser`).
- **tool**: a case change, a digit, a `v` and a digit after the word, and a
  plural `s`; in capitals the word also counts inside a longer run of
  capitals (`MYFOOURL`). Two tools are named with ordinary English words;
  those count only in a tool's own forms, listed below.
- **vocab**: a plural `s`. A camelCase identifier does not split.

A tool's own forms, with `<word>` for the word:

| form | example |
|---|---|
| a path, as of an image, a package or a URL, ending in the word, with a tag, a digest or neither, after a space, a quote, `=`, `:`, `/` or `@` | `image: example.org/team/<word>:1.0`, `https://example.org/<word>/<word>`, `'@scope/<word>'` |
| the word with a tag or a port, after a space, a quote, `=`, `/` or `@` | `image: <word>:1.0`, `host: <word>:8080`, `http://user:pw@<word>:8080` |
| a service in a URL | `url: http://<word>:8080/rpc` |
| a host among a cluster's service names | `<word>.<namespace>.svc`, `<word>.<namespace>.svc.cluster.local` |
| the tool's endpoints and its session header | `/<word>/rpc`, `/<word>/web`, `X-<word>-Session-Id` |
| the word with a component's suffix, after `-` or `_`: `daemon`, `remote`, `cli`, `web`, `console`, `gtk`, `qt`, `rpc`, `client`, `credentials`, `show` | `apt-get install <word>-daemon`, `<word>_client` |
| a client library's name, and a prefix | `<word>rpc`, `lib<word>`, `media-<word>` |
| the argument of `install`, `pull` or `exec`, options between | `brew install <word>`, `docker exec -it <word> sh` |
| a directory of the word in a relative path | `./<word>/config` |
| a key that is the word alone, and a section or table that names it | `<word>:` at the start of a line, `"<word>": {`, `<word>=1`, `[<word>]`, `[clients.<word>]` |
| a value that is the word alone | `client: <word>`, `CLIENT=<word>`, `"client": "<word>",` |
| a list item that is the word alone | `- <word>`, `[a, <word>]` |
| the word alone in quotes | `case "<word>":` |

`rules.txt` can also let a shape pass for one rule, and each is no wider
than this:

- a typeface family that carries a product's name: `ibm`, the word and
  `sans`, `serif`, `mono` or `math`, with at most one other character
  between them, and the package `@ibm/<word>`;
- a Kubernetes client library's cache type: `cache.<word>` or
  `cache.<word>s` as a name of its own, not after a letter, a digit or `_`
  and not before a `.`;
- a search component's name: `search`, then a space, `_` or `-`, then the
  word, singular, as a name of its own.

Before the rules read a line:

- A line ends at LF, at CR LF and at a CR alone.
- UTF-8 spaces, dashes, quotes and punctuation separate words (U+00A0 to
  U+00BF, U+00D7, U+00F7, U+2000 to U+206F, U+FEFF, U+FF00 to U+FF0F,
  U+FF1A to U+FF20), and so do signs and symbols (U+2100 to U+2BFF:
  letterlike symbols such as the trade mark sign, arrows, mathematical and
  technical signs, box drawing, shapes and dingbats; U+10000 to U+3FFFF,
  emoji among them) and three scripts written without spaces between words,
  Chinese, Japanese kana and Korean Hangul (U+3000 to U+9FFF, U+AC00 to
  U+D7FF): a word written right after such a character is still flagged.
- Every other character above ASCII joins the word next to it, as a letter
  of another script does. That includes Thai, which is written without
  spaces between words too: its letters, digits and signs (U+0E00 to
  U+0E7F) join a word, so a word written right after Thai text is not
  flagged, while a space before or after it separates it as anywhere.
- A run of 40 or more base64 characters (`A-Z`, `a-z`, `0-9`, `+`, `/`) is
  skipped when it mixes upper- and lower-case letters, holds digits in three
  places or more (a place is one digit or several), and holds four or more
  lower-case letters that stand alone, with no lower-case letter on either
  side: lock-file hashes and data URIs, which spell short words by chance,
  look like that. An identifier or a path is written in words, so its
  lower-case letters stand together, and it is read whatever its length and
  its digits (`testFooReturns404Then500Then200`, `/srv/Media2/Apps3/Config4/`).
  It is skipped only if four of its letters stand alone, as in four words
  such as `v3`, `Is` or a directory of one letter.

## What it reads

- Every file `git ls-files` lists, hidden files and `.github/` included, as
  it stands in the working tree. A file that is tracked though it matches
  `.gitignore` is read too.
- Never an untracked file: build output and installed dependencies are left
  alone unless they are committed.
- A file that holds a NUL byte counts as binary and is skipped.
- Symbolic links and submodules are skipped and counted.
- A tracked file that is not in the working tree (deleted, replaced by a
  directory, left out by a sparse checkout) stops the check with exit
  status 2.
- When no file is read at all, the check stops with exit status 2 rather
  than call the repository clean.

## Prose and code

A file is prose or code by its kind, never by its directory: `docs/guide.md`
is prose, `docs/examples/values.yaml` is configuration. Prose is, whatever
the case of the name:

- a file ending in `.md`, `.markdown`, `.mdown`, `.mkd`, `.mkdn`, `.mdx`,
  `.rst`, `.txt`, `.text`, `.adoc`, `.asciidoc`, `.org`, `.rdoc`, `.pod`,
  `.tex`, `.textile`, `.wiki` or `.license`, except `CMakeLists.txt` and the
  names that hold `requirements` or `constraints` and end in `.txt`, which
  are configuration;
- a file named, without an extension, `README`, `LICENSE`, `LICENCE`,
  `COPYING`, `NOTICE`, `CHANGELOG`, `CHANGES`, `HISTORY`, `NEWS`, `AUTHORS`,
  `CONTRIBUTORS`, `CONTRIBUTING`, `CODE_OF_CONDUCT`, `SECURITY`, `SUPPORT`,
  `MAINTAINERS`, `GOVERNANCE`, `PATENTS`, `CREDITS`, `THANKS`, `UNLICENSE`
  or `COPYRIGHT`;
- a file named `LICENSE-`, `LICENCE-` or `COPYING-` and a suffix without a
  dot, such as `LICENSE-MIT`.

Everything else is code and configuration.

## Exceptions

A path that has to stay as it is goes into `exceptions`, one per line: the
path, one or more spaces, and the reason, in at least three words.

```text
# Blank lines and comments are fine.
examples/published/    the published example, as it is released
schema/legacy.json     a published contract; changing it breaks its readers
```

- A path ending in `/` is a directory and covers everything under it. It
  matches from the start of a path only: `gen/` covers `gen/a.go`, not
  `src/gen/a.go`.
- Any other path is one file, matched exactly.
- A path cannot hold a space; name its directory instead.
- Every rule skips an excepted path. The log lists each exception with its
  reason and the number of files it covers.
- An exception without a reason, with a reason of fewer than three words (a
  word holds a letter), or one that matches no tracked file stops the check
  with exit status 2: a stale exception goes.
- So does a reason that holds a word a rule flags, read as code: the log
  prints every reason, and never a rule's word.
- Blank lines and lines starting with `#` are ignored.

## The marker

A line that carries `neutrality-guard:allow` is skipped by every rule. It is
for the line that has to name a word, such as a test asserting that a word is
absent from its output. It works per line, so its neighbours are still read,
and the log names every line that carries it, as `path:line`. On a line of
more than 4000 bytes the marker allows nothing: one marker cannot switch off
a minified file, nor a file whose lines end in a CR alone.

## What the log shows

Every line the check prints starts with `neutrality: `. For a flagged line,
its path, its line number and the rule, never the line's text:

```text
neutrality: src/client.go:42: tool
```

A path, an exception's path and its reason are printed with `\` and every
control character escaped (`\\`, `\n`, `\r`, `\t`, `\xHH`), so no name can
start a line of the log or end one early. No message repeats a word of a
rule: an error in `rules.txt` or `cases.txt` names the line, and a field or
a word by its number, and an exception whose reason holds a word is refused
before the log prints it.

## Exit status

| status | meaning |
|---|---|
| 0 | clean |
| 1 | at least one finding; every rule has run |
| 2 | a case gone wrong, a bad or stale exception, a tracked file missing, no file read, or a tool failing (a git or grep error never reads as clean, nor a grep that names a file in another way than it was given) |

## Running it locally

From the root of the repository to check:

```sh
git clone https://github.com/zaentrum/.github.git /tmp/zaentrum-dotgithub
bash /tmp/zaentrum-dotgithub/neutrality/check.sh --exceptions exceptions.txt
```

`--root DIR` checks another repository, `--self-test` runs only the cases,
and `--help` lists the options. The check needs bash 3.2 or later, git, and
grep, sed, tr, cut, wc and sort, in their GNU or BSD forms.

## Changing the check

A change to a rule comes with cases in `cases.txt` that fail without it. The
self-test fails unless every word of every rule has a hit case that the word
alone flags, a rule read everywhere has a case that it flags in prose, a
rule read in code only has a prose case that it flags in code, and every
shape a rule lets pass has a miss case that only that shape lets pass.
`bash neutrality/test.sh` tests the check's own behaviour (which files it
reads, the scopes, the marker, the exceptions, the log and the exit status)
on throwaway repositories. This repository's workflow runs both on every
pull request and on main.

#!/usr/bin/env bash
set +x
# Tests of the neutrality check's own behaviour: which files it reads, the
# rules' scopes, the marker, the exceptions, its exit status, and that its log
# never shows a flagged line's text or a rule's words. Each test builds a
# throwaway git repository under a temporary directory and runs check.sh over
# it. The patterns themselves are tested by the cases in cases.txt, which
# check.sh runs before every scan.
#
# Run: bash neutrality/test.sh   (exit 0 when every test passes)
#
# The words it plants come from rules.txt, so that they stand in one place.
set -u
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
check=$here/check.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/neutrality-test.XXXXXX") || exit 2
work=$(cd "$work" && pwd -P) || exit 2
trap 'chmod -R u+rwx "$work" 2> /dev/null; rm -rf "$work"' EXIT
# The tests' repositories see no user or system git configuration.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=$work

# The plain words of the rules, one per line: every word that is letters only.
plain_words() {
  local id scope flags words w
  local -a ws
  while read -r id scope flags words; do
    [[ $id == pass ]] && continue
    IFS='|' read -r -a ws <<< "$words"
    for w in "${ws[@]}"; do
      [[ $w =~ ^[a-z]+$ ]] && printf '%s\n' "$w"
    done
  done < <(grep -v -E '^[[:space:]]*(#|$)' "$here/rules.txt")
}
# word_of <rule>: the first plain word of the rule's first line.
word_of() {
  local id scope flags words w
  local -a ws
  while read -r id scope flags words; do
    [[ $id == "$1" ]] || continue
    IFS='|' read -r -a ws <<< "$words"
    for w in "${ws[@]}"; do
      if [[ $w =~ ^[a-z]+$ ]]; then
        printf '%s' "$w"
        return 0
      fi
    done
  done < <(grep -v -E '^[[:space:]]*(#|$)' "$here/rules.txt")
  return 1
}
cap() { printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"; }

P=$(word_of product) && T=$(word_of tool) && V=$(word_of vocab) || {
  echo "test: rules.txt has no plain word for each of the rules product, tool and vocab"
  exit 2
}
plain_words > "$work/words" || exit 2

passed=0 failed=0 name= out= status=

# repo <name>: a new, empty git repository, made the current directory.
repo() {
  name=$1
  mkdir -p "$work/$name" && cd "$work/$name" && git -c init.defaultBranch=main init -q || exit 2
}
# put <path> <line>...: write the lines to <path> and stage it.
put() {
  local p=$1
  shift
  mkdir -p "$(dirname "$p")" || exit 2
  printf '%s\n' "$@" > "$p"
  git add -f -- "$p" || exit 2
}
# commit: commit what is staged, as a throwaway identity without an address.
commit() { git -c user.name=test -c user.email= commit -q -m test || exit 2; }
# run <argument>...: run the check over the current repository.
run() {
  out=$(bash "$check" "$@" 2>&1 < /dev/null)
  status=$?
}
# The output, for a failure's report, without any line that holds a word of
# the rules: should the check ever print a line's text, this does not repeat it.
shown() {
  printf '%s\n' "$out" | grep -v -i -F -f "$work/words" | sed 's/^/      | /'
}
fail() {
  failed=$((failed + 1))
  printf 'FAIL %s: %s (exit %s)\n' "$name" "$1" "$status"
  shown
}
# expect <status> [has <line>]... [lacks <line>]... [contains <text>]...
#   [omits <text>]...
expect() {
  local want=$1 ok=1
  shift
  if [[ $status != "$want" ]]; then
    fail "exit $status, not $want"
    return
  fi
  while (($#)); do
    case $1 in
      has) printf '%s\n' "$out" | grep -q -x -F -e "$2" || { fail "no line '$2'"; ok=0; } ;;
      lacks) printf '%s\n' "$out" | grep -q -x -F -e "$2" && { fail "a line '$2'"; ok=0; } ;;
      contains) printf '%s\n' "$out" | grep -q -F -e "$2" || { fail "nothing that says '$2'"; ok=0; } ;;
      omits) printf '%s\n' "$out" | grep -q -i -F -e "$2" && { fail "something that says '$2'"; ok=0; } ;;
      *) echo "test: unknown expectation $1"; exit 2 ;;
    esac
    shift 2
  done
  [[ $ok == 1 ]] && passed=$((passed + 1))
}
# no_words: the output holds no word of any rule.
no_words() {
  if printf '%s\n' "$out" | grep -q -i -F -f "$work/words"; then
    fail "the log holds a word of the rules"
  else
    passed=$((passed + 1))
  fi
}

# ── exit status and the log ──────────────────────────────────────────────────
repo clean
put README.md 'A plain line.'
put main.go 'package main'
run
expect 0 contains 'self-test: ' has 'neutrality: clean'

repo finding
put main.go 'package main' "const name = \"x_${V}_y\""
run
expect 1 has 'neutrality: main.go:2: vocab' contains '1 finding in 1 file'

repo log-without-text
put main.go "SENTINEL_TEXT_42 = ${T} ${P} ${V}"
run
expect 1 has 'neutrality: main.go:1: product' has 'neutrality: main.go:1: tool' has 'neutrality: main.go:1: vocab' \
  omits SENTINEL_TEXT_42
no_words

repo every-rule-runs
put a.go "${T}"
put b.go "${P}"
put c.go "${V}"
run
expect 1 has 'neutrality: a.go:1: tool' has 'neutrality: b.go:1: product' has 'neutrality: c.go:1: vocab' \
  contains '(product 1, tool 1, vocab 1)'

repo root-option
put main.go "${T}"
cd "$work" || exit 2
run --root "$work/root-option"
expect 1 has 'neutrality: main.go:1: tool'
cd "$work/root-option/" && mkdir -p sub && cd sub || exit 2
run
expect 1 has 'neutrality: main.go:1: tool'

name=not-a-repository
mkdir -p "$work/plain" && cd "$work/plain" || exit 2
run
expect 2

name=unknown-argument
cd "$work/clean" || exit 2
run --frobnicate
expect 2

repo zero-files
run
expect 2 contains 'nothing can be called clean' lacks 'neutrality: clean'

repo all-left-out
put main.go 'package main'
printf '%s\n' 'main.go  made by a generator' > "$work/exc-all"
run --exceptions "$work/exc-all"
expect 2 contains '0 read' contains 'nothing can be called clean'

# A trace, asked for or inherited, shows neither a line's text nor a rule.
repo xtrace
put main.go "SENTINEL_TEXT_42 x ${T} y"
out=$(env SHELLOPTS=xtrace bash "$check" 2>&1 < /dev/null)
status=$?
expect 1 has 'neutrality: main.go:1: tool' omits SENTINEL_TEXT_42
no_words
out=$(bash -x "$check" 2>&1 < /dev/null)
status=$?
expect 1 has 'neutrality: main.go:1: tool' omits SENTINEL_TEXT_42
no_words

# ── scope: vocabulary in code and configuration, decided by the file's kind ──
repo vocab-in-prose
put README.md "about x_${V}_y"
put notes.txt "${V}"
put LICENSE-THIRD-PARTY "${V}"
put sub/LICENSE "${V}"
put README "${V}"
put NOTICE "${V}"
put CHANGELOG "${V}"
put docs/README.MD "${V}"
put guide.rst "${V}"
put guide.mdx "${V}"
put guide.markdown "${V}"
put manual.adoc "${V}"
put docs.md "${V}"
put LICENSES/MIT.license "${V}"
run
expect 0

repo vocab-in-code
put main.go 'package main' "var x = \"${V}\""
put config.yaml "key: ${V}-name"
run
expect 1 has 'neutrality: main.go:2: vocab' has 'neutrality: config.yaml:1: vocab'

repo vocab-by-kind-not-directory
put docs/a.go "${V}"
put docs/examples/values.yaml "key: ${V}"
put src/docs/handler.go "${V}"
put doc/b.go "${V}"
put requirements.txt "${V}-client==1.0"
put CMakeLists.txt "add_library(${V} STATIC x.c)"
put license.go "${V}"
run
expect 1 has 'neutrality: docs/a.go:1: vocab' has 'neutrality: docs/examples/values.yaml:1: vocab' \
  has 'neutrality: src/docs/handler.go:1: vocab' has 'neutrality: doc/b.go:1: vocab' \
  has 'neutrality: requirements.txt:1: vocab' has 'neutrality: CMakeLists.txt:1: vocab' \
  has 'neutrality: license.go:1: vocab'

repo products-and-tools-in-prose
put README.md "the ${T} tool"
put docs/x.md "the $(cap "$P") app"
run
expect 1 has 'neutrality: README.md:1: tool' has 'neutrality: docs/x.md:1: product'

# ── camelCase ────────────────────────────────────────────────────────────────
repo camel-product
put App.kt "val my$(cap "$P")Token = 1"
run
expect 1 has 'neutrality: App.kt:1: product'

repo camel-tools-not-vocabulary
put App.kt "val my$(cap "$T")Url = 1" "val my$(cap "$V")Url = 1"
run
expect 1 has 'neutrality: App.kt:1: tool' lacks 'neutrality: App.kt:2: vocab'

repo camel-counted-once
put App.kt "${P} my$(cap "$P")Token"
run
expect 1 has 'neutrality: App.kt:1: product' contains '1 finding in 1 file'

# ── the marker ───────────────────────────────────────────────────────────────
repo marker
put main.go "a ${V} ${T} ${P} b // neutrality-guard:allow" "a ${V} b"
run
expect 1 has 'neutrality: main.go:2: vocab' lacks 'neutrality: main.go:1: vocab' lacks 'neutrality: main.go:1: tool' \
  lacks 'neutrality: main.go:1: product' has 'neutrality: 1 line carries neutrality-guard:allow:' \
  has 'neutrality: main.go:1: carries the marker, so no rule reads the line'

# A CR alone ends a line too: the marker covers its own line only.
repo marker-cr-only
printf 'one\rtwo %s\rthree %s // neutrality-guard:allow\rfour _%s_\r' "${T}" "${P}" "${V}" > cr.go
git add cr.go || exit 2
run
expect 1 has 'neutrality: cr.go:2: tool' has 'neutrality: cr.go:4: vocab' lacks 'neutrality: cr.go:3: product' \
  has 'neutrality: cr.go:3: carries the marker, so no rule reads the line'

# A marker on a line of more than 4000 bytes allows nothing; at 4000 it does.
repo marker-long-line
pad=$(head -c 3900 /dev/zero | tr '\000' 'a')
line="x ${T} y // neutrality-guard:allow "
fill=$(head -c $((4000 - ${#line})) /dev/zero | tr '\000' 'b')
printf '%s%s\n' "$line" "$fill" > at4000.js
printf '%s%sc\n' "$line" "$fill" > over4000.js
printf '%s // neutrality-guard:allow %s;%s\n' "$pad" "${T}" "$pad" > min.js
git add at4000.js over4000.js min.js || exit 2
run
expect 1 lacks 'neutrality: at4000.js:1: tool' has 'neutrality: over4000.js:1: tool' has 'neutrality: min.js:1: tool' \
  has 'neutrality: min.js:1: carries the marker on a line of more than 4000 bytes, so the marker allows nothing' \
  has 'neutrality: at4000.js:1: carries the marker, so no rule reads the line'

# ── exceptions ───────────────────────────────────────────────────────────────
repo exception-exact
put main.go "${T} ${P} ${V}"
put other.go 'package other'
printf '%s\n' 'main.go  made by a generator' > "$work/exc-exact"
run --exceptions "$work/exc-exact"
expect 0 has 'neutrality: leaves out main.go (1 file): made by a generator'

repo exception-prefix
put gen/a.go "${T}"
put gen/sub/b.go "${V}"
put main.go 'package main'
printf '%s\n' '# what is left out' '' 'gen/   vendored, as published' > "$work/exc-prefix"
run --exceptions "$work/exc-prefix"
expect 0 has 'neutrality: leaves out gen/ (2 files): vendored, as published'

repo exception-prefix-not-substring
put gen/a.go "${T}"
put src/gen/x.go "${T}"
put generated.go "${T}"
printf '%s\n' 'gen/  copied from upstream as is' > "$work/exc-substring"
run --exceptions "$work/exc-substring"
expect 1 has 'neutrality: src/gen/x.go:1: tool' has 'neutrality: generated.go:1: tool' lacks 'neutrality: gen/a.go:1: tool'

repo exception-exact-is-not-a-prefix
put main.go "${T}"
printf '%s\n' 'main  a prefix of a name, which is no exception' > "$work/exc-notprefix"
run --exceptions "$work/exc-notprefix"
expect 2 contains 'matches no tracked file'

repo exception-without-reason
put main.go "${T}"
printf '%s\n' 'main.go' > "$work/exc-noreason"
run --exceptions "$work/exc-noreason"
expect 2 contains 'main.go has no reason'

repo exception-reason-too-short
put main.go "${T}"
printf '%s\n' 'main.go  x' > "$work/exc-short1"
run --exceptions "$work/exc-short1"
expect 2 contains 'shorter than 3 words'
printf '%s\n' 'main.go  # # #' > "$work/exc-short2"
run --exceptions "$work/exc-short2"
expect 2 contains 'shorter than 3 words'

repo exception-stale
put main.go 'package main'
printf '%s\n' 'gone.go  it was here once' > "$work/exc-stale"
run --exceptions "$work/exc-stale"
expect 2 contains 'gone.go matches no tracked file'

repo exception-directory-without-slash
put gen/a.go 'package gen'
printf '%s\n' 'gen  copied from upstream as is' > "$work/exc-noslash"
run --exceptions "$work/exc-noslash"
expect 2 contains 'a directory ends in /'

name=exception-file-missing
cd "$work/clean" || exit 2
run --exceptions "$work/no-such-file"
expect 2

# A reason that a rule flags is refused: the log would print the word.
repo exception-reason-holds-a-word
put main.go "${T}"
put other.go 'package other'
printf '%s\n' "main.go  kept for the ${T} tests" > "$work/exc-word-tool"
run --exceptions "$work/exc-word-tool"
expect 2 has 'neutrality: exceptions:1: the reason for main.go holds a word that rule tool flags; reword it, as the log prints every reason' \
  contains 'no scan was made'
no_words
printf '%s\n' "main.go  kept as the ${V} files are" > "$work/exc-word-vocab"
run --exceptions "$work/exc-word-vocab"
expect 2 contains 'holds a word that rule vocab flags'
no_words
# A longer word that holds a rule's word is no word of the rule.
printf '%s\n' "main.go  kept as x${P}x writes it" > "$work/exc-longer-word"
run --exceptions "$work/exc-longer-word"
expect 0 has "neutrality: leaves out main.go (1 file): kept as x${P}x writes it"

# A reason is printed with its control characters escaped.
repo exception-reason-escaped
put main.go 'package main'
put other.go 'package other'
printf 'main.go  kept as it is\r::error::crafted after a carriage return\n' > "$work/exc-cr"
run --exceptions "$work/exc-cr"
expect 0 has 'neutrality: leaves out main.go (1 file): kept as it is\r::error::crafted after a carriage return'

# ── which files are read ─────────────────────────────────────────────────────
repo hidden-file
put .env.example "URL=http://${T}:1"
run
expect 1 has 'neutrality: .env.example:1: tool'

repo dot-github
put .github/workflows/ci.yml "run: ${T}"
run
expect 1 has 'neutrality: .github/workflows/ci.yml:1: tool'

repo untracked-not-read
put README.md 'A plain line.'
printf '%s\n' "${T}" > untracked.go
mkdir -p node_modules/x && printf '%s\n' "${V}" > node_modules/x/index.js
run
expect 0 contains '1 tracked file: 1 read'

repo ignored-but-tracked
put .gitignore 'ignored.go'
put ignored.go "${V}"
run
expect 1 has 'neutrality: ignored.go:1: vocab'

repo binary-skipped
printf 'a\000b\n%s\n' "${T}" > early.bin
{ printf '%s\n' "${T}"; head -c 70000 /dev/zero | tr '\000' 'x'; printf '\000\n'; } > late.dat
# Large, with a NUL at the start: far more than a pipe holds.
{ printf '\000%s\n' "${T}"; head -c 1000000 /dev/zero | tr '\000' 'y'; } > large.bin
git add early.bin late.dat large.bin || exit 2
put main.go 'package main'
run
expect 0 contains '4 tracked files: 1 read, 3 binary'

repo empty-file
: > empty.go
git add empty.go || exit 2
run
expect 0 contains '1 tracked file: 1 read'

repo crlf
printf 'one\r\ntwo %s\r\nthree\r\nfour _%s_\r\n' "${T}" "${V}" > crlf.go
git add crlf.go || exit 2
run
expect 1 has 'neutrality: crlf.go:2: tool' has 'neutrality: crlf.go:4: vocab'

repo space-in-path
put 'dir with space/file name.go' "${V}"
run
expect 1 has 'neutrality: dir with space/file name.go:1: vocab'

repo links-and-submodules
put real.go 'package x'
ln -s "${T}.yaml" link.yaml && git add link.yaml || exit 2
git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,vendor/thing || exit 2
run
expect 0 contains '3 tracked files: 1 read, 0 binary, 0 left out, 2 links or submodules'

# A file named -: read as a file, never as standard input.
repo file-named-dash
printf '%s\n' "${T}" > ./-
git add -- ./- || exit 2
out=$(printf '%s\n' "${P}" | bash "$check" 2>&1)
status=$?
expect 1 has 'neutrality: -:1: tool' lacks 'neutrality: -:1: product'

# A name is escaped, and no line of the log starts with it.
repo names-escaped
f1='::error title=crafted::from a file name'
f2=$'a.go\n::add-mask::x\nneutrality: clean'
printf '%s\n' "${T}" > "./$f1"
printf '%s\n' "${T}" > "./$f2"
git add -- "./$f1" "./$f2" || exit 2
run
expect 1 has 'neutrality: ::error title=crafted::from a file name:1: tool' \
  has 'neutrality: a.go\n::add-mask::x\nneutrality: clean:1: tool' lacks 'neutrality: clean'
if printf '%s\n' "$out" | grep -v -e '^neutrality: ' | grep -q .; then
  fail "a line of the log does not start with neutrality: "
else
  passed=$((passed + 1))
fi

# ── tracked files missing from the working tree stop the check ───────────────
repo missing-file
put main.go "${T}"
put ok.go 'package x'
rm main.go
run
expect 2 contains 'main.go: tracked, but not a file in the working tree' contains 'no scan was made'

repo replaced-by-directory
put main.go "${T}"
rm main.go && mkdir main.go || exit 2
run
expect 2 contains 'not in the working tree'

repo sparse-checkout
put src/a.go "${T}"
put keep/b.go 'package x'
commit
if git sparse-checkout set keep > /dev/null 2>&1 && [[ ! -e src/a.go ]]; then
  run
  expect 2 contains 'src/a.go: tracked, but not a file in the working tree'
else
  echo "skip $name: this git makes no sparse checkout"
fi

# ── the check's own directory, and a check beside the repository ─────────────
repo own-directory
mkdir -p neutrality && cp "$check" "$here/rules.txt" "$here/cases.txt" neutrality/ || exit 2
git add neutrality || exit 2
put main.go 'package main'
out=$(bash neutrality/check.sh 2>&1 < /dev/null)
status=$?
expect 0 contains 'leaves out neutrality/ (3 files): lists what it bans'

repo another-neutrality-directory
put neutrality/x.go "${V}"
run
expect 1 has 'neutrality: neutrality/x.go:1: vocab'

# The layout of the called workflow: the repository and the check in two
# sibling directories. The repository's own neutrality/ and check/ are read.
name=sibling-paths
mkdir -p "$work/ws/check/neutrality" && cp "$check" "$here/rules.txt" "$here/cases.txt" "$work/ws/check/neutrality/" || exit 2
mkdir -p "$work/ws/repository" && cd "$work/ws/repository" && git -c init.defaultBranch=main init -q || exit 2
put neutrality/x.go "${V}"
put check/neutrality/y.go "${T}"
put main.go 'package main'
cd "$work/ws" || exit 2
out=$(bash check/neutrality/check.sh --root repository 2>&1 < /dev/null)
status=$?
expect 1 has 'neutrality: neutrality/x.go:1: vocab' has 'neutrality: check/neutrality/y.go:1: tool' omits 'leaves out'

# ── failures are failures, never a pass ──────────────────────────────────────
name=self-test
cd "$work/clean" || exit 2
run --self-test
expect 0 contains 'cases passed'

# broken <name>: a copy of the check in $work/<name>, to break.
broken() {
  name=$1
  mkdir -p "$work/$name" && cp "$check" "$here/rules.txt" "$here/cases.txt" "$work/$name/" || exit 2
}
# self_test_of <name>: run the broken copy's self-test.
self_test_of() {
  out=$(bash "$work/$1/check.sh" --self-test 2>&1 < /dev/null)
  status=$?
}
broken case-gone-wrong
printf '%s\n' 'hit vocab a line with nothing in it' >> "$work/case-gone-wrong/cases.txt"
cd "$work/finding" || exit 2
self_test_of case-gone-wrong
expect 2 contains 'does not flag this case, and must'
out=$(bash "$work/case-gone-wrong/check.sh" 2>&1 < /dev/null)
status=$?
expect 2 lacks 'neutrality: main.go:2: vocab' contains 'no scan was made'

broken case-unknown-rule
printf '%s\n' "miss $(cap "$T") some text" >> "$work/case-unknown-rule/cases.txt"
self_test_of case-unknown-rule
expect 2 contains 'names no rule of rules.txt'
no_words

broken rule-without-hit-case
grep -v -E '^(prose-)?hit vocab ' "$here/cases.txt" > "$work/rule-without-hit-case/cases.txt"
self_test_of rule-without-hit-case
expect 2 contains 'no hit case or no miss case for rule vocab'

broken rules-bad-scope
sed -E 's/^(vocab[[:space:]]+)code/\1everywhere/' "$here/rules.txt" > "$work/rules-bad-scope/rules.txt"
self_test_of rules-bad-scope
expect 2 contains 'field 2, the scope, is all or code' omits everywhere

# The fields in the wrong order: no message repeats the rule's words.
broken rules-swapped
sed -E 's/^(tool[[:space:]]+all[[:space:]]+)([^[:space:]]+)[[:space:]]+([^[:space:]]+)$/\1\3 \2/' "$here/rules.txt" > "$work/rules-swapped/rules.txt"
self_test_of rules-swapped
expect 2 contains 'rules.txt:'
no_words

# Every word has a hit case of its own; every scope and every pass is pinned.
broken word-without-case
sed -E 's/^(vocab[[:space:]].*)$/\1|newword/' "$here/rules.txt" > "$work/word-without-case/rules.txt"
self_test_of word-without-case
expect 2 contains 'has no hit case of its own'

broken word-cases-gone
grep -v -i -F -e "${T}" "$here/cases.txt" > "$work/word-cases-gone/cases.txt"
self_test_of word-cases-gone
expect 2 contains 'word 1 of rule tool has no hit case of its own'

broken scope-to-code
sed -E 's/^(tool[[:space:]]+)all/\1code/' "$here/rules.txt" > "$work/scope-to-code/rules.txt"
self_test_of scope-to-code
expect 2 contains 'does not flag this case, and must'

broken scope-to-all
sed -E 's/^(vocab[[:space:]]+)code/\1all /' "$here/rules.txt" > "$work/scope-to-all/rules.txt"
self_test_of scope-to-all
expect 2 contains 'to pin its scope all'

broken pass-without-case
grep -v -i -F -e "cache.${V}" "$here/cases.txt" > "$work/pass-without-case/cases.txt"
self_test_of pass-without-case
expect 2 contains 'only this pass lets pass'

# A grep that fails on the repository's files, though not on the cases: the
# scan must end with 2, never read the failure as a clean file.
name=grep-fails
mkdir -p "$work/fakebin" || exit 2
real_grep=$(command -v grep)
printf '#!/bin/sh\nfor a; do case $a in *.go) echo "grep: failing on purpose" >&2; exit 2 ;; esac; done\nexec "%s" "$@"\n' \
  "$real_grep" > "$work/fakebin/grep"
chmod +x "$work/fakebin/grep"
cd "$work/clean" || exit 2
out=$(PATH="$work/fakebin:$PATH" bash "$check" 2>&1 < /dev/null)
status=$?
expect 2 contains 'grep failed'

# A grep -l that names the files in another way than they were given (here
# without the leading ./): the walk must not leave them unread and call the
# repository clean.
mkdir -p "$work/fakebin-names" || exit 2
printf '#!/bin/sh\nfor a; do case $a in -l) "%s" "$@" > "$0.out"; st=$?; sed -e "s#\\./##g" "$0.out"; exit $st ;; esac; done\nexec "%s" "$@"\n' \
  "$real_grep" "$real_grep" > "$work/fakebin-names/grep"
chmod +x "$work/fakebin-names/grep"
repo grep-names-another-way
put main.go "x ${T} y"
put ok.go 'package x'
out=$(PATH="$work/fakebin-names:$PATH" bash "$check" 2>&1 < /dev/null)
status=$?
expect 2 contains 'grep -l named a file other than as it was given' lacks 'neutrality: clean'
repo grep-names-marker-another-way
put a.go 'nothing here // neutrality-guard:allow'
out=$(PATH="$work/fakebin-names:$PATH" bash "$check" 2>&1 < /dev/null)
status=$?
expect 2 contains 'the lines that carry the marker are not all known' lacks 'neutrality: clean'

repo unreadable-file
put main.go 'package main'
chmod 000 main.go
if [[ -r main.go ]]; then
  echo "skip $name: this user reads a file with mode 000"
else
  run
  expect 2 contains 'cannot read main.go'
fi
chmod 644 main.go

echo "test: $passed passed, $failed failed"
[[ $failed -eq 0 ]]

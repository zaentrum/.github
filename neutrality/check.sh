#!/usr/bin/env bash
set +x # first: a trace would show the lines the check reads, and its rules
# The neutrality check. No public repository of the organisation names
# another media product or a download tool, and none carries the vocabulary
# of acquiring content in its code and configuration. The rules are in
# rules.txt beside this file and their test cases in cases.txt; the rules
# name nothing of any one installation. README.md says how a repository runs
# the check.
#
# Usage: check.sh [--root DIR] [--exceptions FILE]
#        check.sh --self-test
#
#   --root DIR         check the git repository DIR is in (default: the one
#                      the current directory is in)
#   --exceptions FILE  paths to leave out, one per line: the path, spaces,
#                      and the reason, of at least three words and with no
#                      word a rule flags. A path ending in / is a directory
#                      and covers everything under it.
#   --self-test        run the cases in cases.txt and stop
#
# What it reads: every file git tracks, hidden ones and .github/ included,
# as it stands in the working tree. It never reads an untracked file, and it
# skips a file that holds a NUL byte as binary. A tracked file that is not in
# the working tree stops it. The cases run before every scan.
#
# What it prints: for a flagged line, the path, the line number and the
# rule, never the line's text; for a line that carries the marker, the path
# and the line number. Every line it prints starts with "neutrality: ", and a
# path or a reason is printed with its control characters escaped.
#
# Exit status: 0 clean; 1 at least one finding (every rule still runs);
# 2 a case gone wrong, a bad or stale exception, a tracked file missing, no
# file read at all, or a tool failing (grep -l naming a file in another way
# than it was given included).
#
# Needs bash 3.2 or later, git, and grep, sed, tr, cut, wc and sort in their
# GNU or BSD forms.
set -u
export LC_ALL=C

marker='neutrality-guard:allow'
# A marker on a line longer than this many bytes allows nothing: one marker
# must not switch off a minified file or a file whose lines end in CR alone.
long_line=4000
# An exception's reason has at least this many words.
reason_words=3
# A run of at least b64_min base64 characters (A-Z a-z 0-9 + /) that mixes
# upper- and lower-case letters, holds digits in three places or more and
# holds b64_lone or more lower-case letters that stand alone is skipped:
# lock-file hashes and data URIs spell short words by chance.
b64_min=40
b64_lone=4
# Files per grep call: well below any system's limit on arguments.
chunk=200
blank_re='^[[:space:]]*(#|$)'
us=$'\037' # the sed delimiter for a pass's shape, which holds no control character

say() { printf 'neutrality: %s\n' "$*"; }
# count <n> <thing>: "1 file", "2 files".
count() { if [[ $1 -eq 1 ]]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi; }
die() { printf 'neutrality: %s\n' "$*" >&2; exit 2; }

# esc <text>: sets E to the text with \ and every control character written
# as an escape (\\ \n \r \t \xHH): a name or a reason from the repository
# checked can neither start a line of the log nor end one early.
esc() {
  local i h c
  E=${1//\\/\\\\}
  E=${E//$'\n'/\\n}
  E=${E//$'\r'/\\r}
  E=${E//$'\t'/\\t}
  case $E in
    *[[:cntrl:]]*)
      for ((i = 1; i < 128; i++)); do
        ((i < 32 || i == 127)) || continue
        printf -v h '%02x' "$i"
        printf -v c "\\x$h"
        E=${E//"$c"/\\x$h}
      done
      ;;
  esac
}

# The letters, for changing case without a subshell.
letters='a:A b:B c:C d:D e:E f:F g:G h:H i:I j:J k:K l:L m:M n:N o:O p:P q:Q r:R s:S t:T u:U v:V w:W x:X y:Y z:Z'
# lower <text>: sets LOW to the text in lower case.
lower() {
  local p
  LOW=$1
  for p in $letters; do LOW=${LOW//${p#*:}/${p%:*}}; done
}
# upper_re <regex>: sets UP to the regular expression with its letters in
# upper case, its character class names ([:alnum:] and the like) kept.
upper_re() {
  local p c C
  UP=$1
  for p in $letters; do UP=${UP//${p%:*}/${p#*:}}; done
  for c in alnum alpha blank cntrl digit graph lower print punct space upper xdigit; do
    C=$c
    for p in $letters; do C=${C//${p%:*}/${p#*:}}; done
    UP=${UP//"[:$C:]"/"[:$c:]"}
  done
}

usage() {
  cat <<'EOF'
Usage: check.sh [--root DIR] [--exceptions FILE]
       check.sh --self-test

Checks every file git tracks in DIR's repository (default: the current
directory's) against the rules in rules.txt, after running the cases in
cases.txt. Prints path:line: rule for each flagged line, never its text.

  --root DIR         the repository to check
  --exceptions FILE  paths to leave out, one per line: path, spaces, reason
                     of at least three words, none a rule flags; a path
                     ending in / covers everything under it
  --self-test        run the cases only

Exit status: 0 clean, 1 findings, 2 a case gone wrong, a bad or stale
exception, a tracked file missing, no file read, or a tool failing.
EOF
}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || die "cannot find the directory this script is in"
rules_file=$here/rules.txt
cases_file=$here/cases.txt

root=.
exceptions_file=
self_test_only=0
while (($#)); do
  case $1 in
    --root) [[ $# -ge 2 ]] || die "--root needs a directory"; root=$2; shift 2 ;;
    --root=*) root=${1#*=}; shift ;;
    --exceptions) [[ $# -ge 2 ]] || die "--exceptions needs a file"; exceptions_file=$2; shift 2 ;;
    --exceptions=*) exceptions_file=${1#*=}; shift ;;
    --self-test) self_test_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) esc "$1"; die "unknown argument: $E (check.sh --help says what it takes)" ;;
  esac
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/neutrality.XXXXXX") || die "cannot make a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# ── reading a file as the rules read it ──────────────────────────────────────
# A line ends at LF, at CR LF and at a CR alone. The rules then read each
# line with a space for: the UTF-8 spaces, dashes, quotes and punctuation
# (U+00A0-U+00BF, U+00D7, U+00F7, U+2000-U+206F, U+FEFF, U+FF00-U+FF0F,
# U+FF1A-U+FF20); the symbols (U+2100-U+2BFF: letterlike symbols, arrows,
# mathematical and technical signs, box drawing, shapes, dingbats; and
# U+10000-U+3FFFF, emoji among them); the scripts written without spaces
# between words that are listed here (U+3000-U+9FFF: the CJK punctuation,
# kana and ideographs; U+AC00-U+D7FF: Hangul); and a long base64 run
# (b64_min above). Every other byte above 127 reads as an x, so that a
# letter of another script joins the word next to it.
utf8_space=$'\xc2[\xa0-\xbf]|\xc3[\x97\xb7]|\xe2\x80[\x80-\xbf]|\xe2\x81[\x80-\xaf]|\xe2[\x84-\xaf][\x80-\xbf]|\xef\xbb\xbf|\xef\xbc[\x80-\x8f\x9a-\xa0]'
utf8_space=$utf8_space$'|\xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf]'
utf8_space=$utf8_space$'|\xe3[\x80-\xbf][\x80-\xbf]|[\xe4-\xe9][\x80-\xbf][\x80-\xbf]|\xea[\xb0-\xbf][\x80-\xbf]|[\xeb\xec][\x80-\xbf][\x80-\xbf]|\xed[\x80-\x9f][\x80-\xbf]'
m1=$'\001' m2=$'\002' m3=$'\003' m4=$'\004' hi1=$'\x80' hi2=$'\xff'
# A base64 run is marked m1...m2, and m3...m2 once it holds digits in three
# places (a place is one digit or more). It is read again unless it mixes
# upper- and lower-case letters and holds b64_lone lower-case letters that
# stand alone, with no lower-case letter on either side: m4 marks those, in
# two passes, as one pass misses a letter whose left neighbour the match
# before it took. An identifier or a path is written in words, so its
# lower-case letters stand together; random base64 has a lone one in about
# every seventh place. The control characters m1-m4 read as spaces in a file.
norm_sed="s/($utf8_space)/ /g
s/[$hi1-$hi2]/x/g
s#[A-Za-z0-9+/]{$b64_min,}#$m1&$m2#g
s#$m1([^$m2]*[0-9][^0-9$m2]+[0-9]+[^0-9$m2]+[0-9][^$m2]*)$m2#$m3\\1$m2#g
s#$m1([^$m2]*)$m2#\\1#g
s#$m3([^A-Z$m2]*)$m2#\\1#g
s#$m3([^a-z$m2]*)$m2#\\1#g
/$m3/s#([^a-z$m4])([a-z])([^a-z])#\\1$m4\\2\\3#g
/$m3/s#([^a-z$m4])([a-z])([^a-z])#\\1$m4\\2\\3#g
s#$m3([^$m2$m4]*($m4[^$m2$m4]*){0,$((b64_lone - 1))})$m2#\\1#g
s#$m4##g
s#$m3[^$m2]*$m2# #g"
# For a rule with the camel flag: a boundary between a lower-case letter or
# a digit and an upper-case letter, and before the last capital of a run of
# capitals that a lower-case letter follows (XMLFoo reads as XML Foo).
camel_sed='s/([[:upper:]])([[:upper:]][[:lower:]])/\1 \2/g
s/([[:lower:][:digit:]])([[:upper:]])/\1 \2/g'

# normalize <file> <lines> [<norm>]: <lines> is <file> with its line ends
# made one; <norm> is <lines> as the rules read it. Returns 2 when a tool
# fails.
normalize() {
  sed -e $'s/\r$//' -- "$1" | tr '\r\001\002\003\004' '\n    ' > "$2"
  [[ ${PIPESTATUS[0]} == 0 && ${PIPESTATUS[1]} == 0 ]] || return 2
  [[ -n ${3-} ]] || return 0
  sed -E -e "$norm_sed" -- "$2" > "$3" || return 2
}

# markers <lines>: sets MARKED to the numbers of the lines that carry the
# marker and LONG to those of them longer than long_line bytes, each list as
# " 3 7 ". Returns 2 when a tool fails.
markers() {
  local n
  MARKED=' ' LONG=' '
  grep -n -a -F -e "$marker" -- "$1" | cut -d: -f1 > "$tmp/marked"
  [[ ${PIPESTATUS[0]} -le 1 && ${PIPESTATUS[1]} == 0 ]] || return 2
  [[ -s $tmp/marked ]] || return 0
  while read -r n; do MARKED="$MARKED$n "; done < "$tmp/marked"
  cut -c "$((long_line + 1))-" -- "$1" | grep -n -a -e . | cut -d: -f1 > "$tmp/long"
  [[ ${PIPESTATUS[0]} == 0 && ${PIPESTATUS[1]} -le 1 && ${PIPESTATUS[2]} == 0 ]] || return 2
  while read -r n; do
    [[ $MARKED == *" $n "* ]] && LONG="$LONG$n "
  done < "$tmp/long"
  return 0
}

# allowed <n>: true when line <n> carries the marker on a line short enough.
allowed() { [[ $MARKED == *" $1 "* && $LONG != *" $1 "* ]]; }

# ── the rules ────────────────────────────────────────────────────────────────
# rules.txt's header says the format. An error message names a line of it,
# and a field or a word by its number, never its text.
r_id=() r_scope=()
n_rules=0
l_rule=() l_n=() l_words=() l_camel=() l_digits=() l_plural=() l_caps=() l_own=() l_re=() l_caps_re=()
n_lines=0
p_rule=() p_shape=() p_n=() p_id=()
n_pass=0

# word_re <rule line> <words>: sets RE, the rule line's regular expression
# for the words, read without regard to case, and CAPS_RE, the one for its
# caps flag, read with regard to case (empty without the flag).
word_re() {
  local l=$1 b='[^[:alnum:]]' a='[^[:alnum:]]' core
  [[ ${l_digits[$l]} == 1 ]] && b='[^[:alpha:]]' a='[^[:alpha:]]|v[0-9]'
  core="($2)"
  [[ ${l_plural[$l]} == 1 ]] && core="${core}s?"
  RE="(^|$b)$core($a|\$)"
  CAPS_RE=
  if [[ ${l_caps[$l]} == 1 ]]; then
    upper_re "$2"
    CAPS_RE="(^|[^[:lower:]])($UP)([^[:lower:]]|\$)"
  fi
}

# own_re <words>: sets RE to the tools' own forms of the words, read without
# regard to case. README.md lists them with an example each.
own_re() {
  local w="($1)" q="[\"'\`]" s='[[:space:]]' e b='(^|[^[:alnum:]])' a='([^[:alnum:]]|$)'
  e="([][:space:]\"'\`,;)>]|\$)"
  # A path ending in the word; the word with a tag or a port.
  RE="(^|[[:space:]\"'\`=:/@])([[:alnum:]_.-]+/)+$w(:[[:alnum:]_.-]+|@sha256:[[:xdigit:]]+)?$e"
  RE="$RE|(^|[[:space:]\"'\`=/@])$w:[[:alnum:]][[:alnum:]_.-]*$e"
  # A service in a URL; a host in a cluster's service names.
  RE="$RE|://$w([:/.[:space:]\"'\`]|\$)"
  RE="$RE|(^|[^[:alnum:]_.-])$w\\.[[:alnum:]-]+\\.svc([^[:alnum:]-]|\$)"
  # A tool's interface: its endpoints and its session header.
  RE="$RE|/$w/(rpc|web)$a|${b}x-$w-session-id$a"
  # A package, a binary or a library: the word with a component's suffix,
  # the client library's names, a prefix.
  RE="$RE|$b$w[-_](daemon|remote|cli|web|console|gtk|qt|rpc|client|credentials|show)$a"
  RE="$RE|$b(lib$w|media-$w|${w}rpc)$a"
  # The argument of install, pull or exec, options between.
  RE="$RE|(^|[^[:alnum:]_-])(install|pull|exec)($s+-[^[:space:]]*)*$s+$w([[:space:];&|)\"'\`=]|\$)"
  # A directory of the word in a relative path.
  RE="$RE|(^|[^[:alnum:]_.])\\.\\.?/$w/"
  # A key that is the word alone, a section or table that names it.
  RE="$RE|^$s*(-$s+)?[\"']?$w[\"']?$s*(:($s|\$)|=)"
  RE="$RE|[{,]$s*[\"']$w[\"']$s*:"
  RE="$RE|^$s*\\[{1,2}([[:alnum:]_-]+\\.)*$w(\\.[[:alnum:]_-]+)*\\]{1,2}$s*\$"
  # A value that is the word alone, an item of a list.
  RE="$RE|[:=]$s*[\"']?$w[\"']?$s*([],;}#]|\$)"
  RE="$RE|^$s*-$s+[\"']?$w[\"']?$s*\$"
  RE="$RE|\\[[^]]*,$s*[\"']?$w[\"']?$s*[],]|\\[$s*[\"']?$w[\"']?$s*,"
  # The word alone in quotes.
  RE="$RE|$q$w$q"
}

# compiles <regex>: true when grep reads the extended regular expression.
compiles() {
  local st
  grep -E -e "$1" < /dev/null > /dev/null 2>&1
  st=$?
  [[ $st -eq 1 ]]
}

load_rules() {
  local line n=0 id scope flags words extra f k r st w
  local -a fl ws
  [[ -f $rules_file && -r $rules_file ]] || die "cannot read $rules_file"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ $blank_re ]] && continue
    id= scope= flags= words= extra=
    read -r id scope flags words extra <<< "$line"
    if [[ $id == pass ]]; then
      [[ -n $flags && -z $words ]] || die "rules.txt:$n: a pass is three fields: pass, a rule's name and a shape"
      [[ $flags != *[[:cntrl:]]* ]] || die "rules.txt:$n: field 3 holds a control character"
      compiles "$flags" || die "rules.txt:$n: field 3 is not an extended regular expression grep reads"
      p_id[$n_pass]=$scope
      p_shape[$n_pass]=$flags
      p_n[$n_pass]=$n
      n_pass=$((n_pass + 1))
      continue
    fi
    [[ -n $words && -z $extra ]] ||
      die "rules.txt:$n: a rule's line is four fields: its name, scope, flags and words (words without spaces)"
    [[ $id =~ ^[a-z][a-z0-9_-]*$ ]] ||
      die "rules.txt:$n: field 1, a rule's name, is lower-case letters, digits, - and _"
    case $scope in
      all|code) ;;
      *) die "rules.txt:$n: field 2, the scope, is all or code" ;;
    esac
    r=-1
    for ((k = 0; k < n_rules; k++)); do
      [[ ${r_id[$k]} == "$id" ]] && r=$k
    done
    if [[ $r -lt 0 ]]; then
      r=$n_rules
      r_id[$r]=$id
      r_scope[$r]=$scope
      n_rules=$((n_rules + 1))
    fi
    [[ ${r_scope[$r]} == "$scope" ]] || die "rules.txt:$n: rule $id has another scope on an earlier line"
    l_camel[$n_lines]=0 l_digits[$n_lines]=0 l_plural[$n_lines]=0 l_caps[$n_lines]=0 l_own[$n_lines]=0
    if [[ $flags != - ]]; then
      IFS=, read -r -a fl <<< "$flags"
      [[ ${#fl[@]} -gt 0 ]] || die "rules.txt:$n: field 3, the flags, is - or a list"
      for f in ${fl[@]+"${fl[@]}"}; do
        case $f in
          camel) l_camel[$n_lines]=1 ;;
          digits) l_digits[$n_lines]=1 ;;
          plural) l_plural[$n_lines]=1 ;;
          caps) l_caps[$n_lines]=1 ;;
          own) l_own[$n_lines]=1 ;;
          *) die "rules.txt:$n: field 3 holds a flag other than camel, digits, plural, caps and own" ;;
        esac
      done
      [[ ${l_own[$n_lines]} == 0 || ${#fl[@]} -eq 1 ]] || die "rules.txt:$n: the flag own goes with no other flag"
    fi
    [[ $words != *[\(\)A-Z]* && $words != *[[:cntrl:]]* ]] ||
      die "rules.txt:$n: field 4, the words, is in lower case, without ( or )"
    [[ $words != '|'* && $words != *'|' && $words != *'||'* ]] || die "rules.txt:$n: field 4 holds an empty word"
    IFS='|' read -r -a ws <<< "$words"
    k=0
    for w in "${ws[@]}"; do
      k=$((k + 1))
      [[ $w =~ ^[a-z0-9] ]] || die "rules.txt:$n: word $k does not start with a letter or a digit"
    done
    l_rule[$n_lines]=$r
    l_n[$n_lines]=$n
    l_words[$n_lines]=$words
    if [[ ${l_own[$n_lines]} == 1 ]]; then
      own_re "$words"
      l_re[$n_lines]=$RE
      l_caps_re[$n_lines]=
    else
      word_re "$n_lines" "$words"
      l_re[$n_lines]=$RE
      l_caps_re[$n_lines]=$CAPS_RE
    fi
    compiles "${l_re[$n_lines]}" || die "rules.txt:$n: field 4 is not an extended regular expression grep reads"
    if [[ -n ${l_caps_re[$n_lines]} ]]; then
      compiles "${l_caps_re[$n_lines]}" || die "rules.txt:$n: field 4 in capitals is not a regular expression grep reads"
    fi
    n_lines=$((n_lines + 1))
  done < "$rules_file"
  [[ $n_rules -gt 0 ]] || die "rules.txt holds no rule"
  for ((k = 0; k < n_pass; k++)); do
    p_rule[$k]=-1
    for ((r = 0; r < n_rules; r++)); do
      [[ ${r_id[$r]} == "${p_id[$k]}" ]] && p_rule[$k]=$r
    done
    [[ ${p_rule[$k]} -ge 0 ]] || die "rules.txt:${p_n[$k]}: the pass names no rule of this file"
  done
}

# lines_matching <case> <regex> <file>: print the numbers of the lines of
# <file> the regular expression matches; <case> is -i to read without regard
# to case, or empty. Returns 2 when grep or cut fails.
lines_matching() {
  grep -n -a ${1:+"$1"} -E -e "$2" -- "$3" | cut -d: -f1
  [[ ${PIPESTATUS[0]} -le 1 && ${PIPESTATUS[1]} == 0 ]] || return 2
}

# hits_of <rule line> <file> [<words>]: print the numbers of the lines of
# <file> the rule line flags, unsorted, the marker not applied. <words>
# stands in for the line's words: the self-test reads each word alone.
# Returns 2 when a tool fails.
hits_of() {
  local l=$1 in=$2 re=${l_re[$1]} caps_re=${l_caps_re[$1]}
  if [[ $# -ge 3 ]]; then
    if [[ ${l_own[$l]} == 1 ]]; then own_re "$3"; else word_re "$l" "$3"; fi
    re=$RE caps_re=${CAPS_RE-}
    [[ ${l_own[$l]} == 1 ]] && caps_re=
  fi
  lines_matching -i "$re" "$in" || return 2
  [[ ${l_own[$l]} == 1 ]] && return 0
  if [[ ${l_camel[$l]} == 1 ]]; then
    sed -E -e "$camel_sed" -- "$in" > "$tmp/split" || return 2
    lines_matching -i "$re" "$tmp/split" || return 2
  fi
  if [[ -n $caps_re ]]; then
    lines_matching "" "$caps_re" "$in" || return 2
  fi
  return 0
}

# passed <rule> <norm> [<pass to leave out>]: sets PIN to the file the rule
# reads: <norm> with the shapes of the rule's passes blanked out. Returns 2
# when sed fails.
passed() {
  local r=$1 skip=${3--1} p script=
  PIN=$2
  for ((p = 0; p < n_pass; p++)); do
    [[ ${p_rule[$p]} == "$r" && $p != "$skip" ]] || continue
    script="$script${script:+$'\n'}s$us${p_shape[$p]}$us#${us}gI"
  done
  [[ -n $script ]] || return 0
  # Silent: a sed that fails may repeat its script, the shapes, in its error.
  sed -E -e "$script" -- "$2" > "$tmp/passed" 2> /dev/null || return 2
  PIN=$tmp/passed
}

# rule_hits <rule> <norm> <prose> [<pass to leave out>]: print the numbers of
# the lines of <norm> the rule flags, lowest first, each once, the marker not
# applied; <prose> is 1 for a file of prose. Returns 2 when a tool fails.
rule_hits() {
  local r=$1 l
  [[ ${r_scope[$r]} == code && $3 == 1 ]] && return 0
  passed "$r" "$2" ${4+"$4"} || return 2
  : > "$tmp/rule_hits"
  for ((l = 0; l < n_lines; l++)); do
    [[ ${l_rule[$l]} == "$r" ]] || continue
    hits_of "$l" "$PIN" >> "$tmp/rule_hits" || return 2
  done
  sort -n -u "$tmp/rule_hits" || return 2
}

# ── the cases ────────────────────────────────────────────────────────────────
# cases.txt's header says the format. The cases of one rule go into one file
# for code and one for prose, which the rule reads as it reads a repository's
# file; each case is then a line of that file the rule must or must not flag.
self_test() {
  local line n=0 kind rule text r k l j w p total=0 bad=0 mode want got hits hits2 pinned
  local -a has_hit has_miss has_phit has_pmiss ws
  [[ -f $cases_file && -r $cases_file ]] || die "cannot read $cases_file"
  for ((r = 0; r < n_rules; r++)); do
    : > "$tmp/case.code.$r"; : > "$tmp/case.code.$r.from"
    : > "$tmp/case.prose.$r"; : > "$tmp/case.prose.$r.from"
    : > "$tmp/case.hits.$r"
    has_hit[$r]=0 has_miss[$r]=0 has_phit[$r]=0 has_pmiss[$r]=0
  done
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ $blank_re ]] && continue
    kind= rule= text=
    read -r kind rule text <<< "$line"
    case $kind in
      hit|miss|prose-hit|prose-miss) ;;
      *) die "cases.txt:$n: a case starts with hit, miss, prose-hit or prose-miss" ;;
    esac
    [[ -n $text ]] || die "cases.txt:$n: a case is its kind, a rule's name and the text"
    if [[ $rule == '*' ]]; then
      [[ $kind == *miss ]] || die "cases.txt:$n: * stands for every rule and goes with miss or prose-miss only"
    else
      k=-1
      for ((r = 0; r < n_rules; r++)); do [[ ${r_id[$r]} == "$rule" ]] && k=$r; done
      [[ $k -ge 0 ]] || die "cases.txt:$n: field 2 names no rule of rules.txt"
    fi
    mode=code
    [[ $kind == prose-* ]] && mode=prose
    for ((r = 0; r < n_rules; r++)); do
      [[ $rule == '*' || $rule == "${r_id[$r]}" ]] || continue
      printf '%s\n' "$text" >> "$tmp/case.$mode.$r"
      printf '%s %s\n' "$n" "$kind" >> "$tmp/case.$mode.$r.from"
      case $kind in
        hit) has_hit[$r]=1; printf '%s\n' "$text" >> "$tmp/case.hits.$r" ;;
        prose-hit) has_phit[$r]=1; printf '%s\n' "$text" >> "$tmp/case.hits.$r" ;;
        miss) has_miss[$r]=1 ;;
        prose-miss) has_pmiss[$r]=1 ;;
      esac
    done
    total=$((total + 1))
  done < "$cases_file"

  for ((r = 0; r < n_rules; r++)); do
    [[ ${has_hit[$r]} == 1 && ${has_miss[$r]} == 1 ]] ||
      die "cases.txt has no hit case or no miss case for rule ${r_id[$r]}"
    # Each case, as code or as prose.
    for mode in code prose; do
      [[ -s $tmp/case.$mode.$r ]] || continue
      normalize "$tmp/case.$mode.$r" "$tmp/case.lines" "$tmp/case.norm.$mode" || die "a tool failed on the cases of rule ${r_id[$r]}"
      markers "$tmp/case.lines" || die "a tool failed on the cases of rule ${r_id[$r]}"
      if [[ $mode == prose ]]; then
        hits=$(rule_hits "$r" "$tmp/case.norm.$mode" 1) || die "a tool failed on the cases of rule ${r_id[$r]}"
      else
        hits=$(rule_hits "$r" "$tmp/case.norm.$mode" 0) || die "a tool failed on the cases of rule ${r_id[$r]}"
      fi
      hits=" $(printf '%s' "$hits" | tr '\n' ' ') "
      k=0
      while read -r n kind; do
        k=$((k + 1))
        got=0
        [[ $hits == *" $k "* ]] && ! allowed "$k" && got=1
        want=0
        [[ $kind == *hit ]] && want=1
        [[ $got == "$want" ]] && continue
        if [[ $got == 1 ]]; then
          say "cases.txt:$n: rule ${r_id[$r]} flags this case, and must not"
        else
          say "cases.txt:$n: rule ${r_id[$r]} does not flag this case, and must"
        fi
        bad=1
      done < "$tmp/case.$mode.$r.from"
    done
    # Every word has a hit case of its own.
    normalize "$tmp/case.hits.$r" "$tmp/case.lines" "$tmp/case.norm.hits" || die "a tool failed on the cases of rule ${r_id[$r]}"
    passed "$r" "$tmp/case.norm.hits" || die "sed failed on the cases of rule ${r_id[$r]}"
    for ((l = 0; l < n_lines; l++)); do
      [[ ${l_rule[$l]} == "$r" ]] || continue
      IFS='|' read -r -a ws <<< "${l_words[$l]}"
      j=0
      for w in "${ws[@]}"; do
        j=$((j + 1))
        hits_of "$l" "$PIN" "$w" > "$tmp/case.word" || die "a tool failed on the cases of rule ${r_id[$r]}"
        if [[ ! -s $tmp/case.word ]]; then
          say "rules.txt:${l_n[$l]}: word $j of rule ${r_id[$r]} has no hit case of its own in cases.txt"
          bad=1
        fi
      done
    done
    # A case pins the rule's scope.
    if [[ ${r_scope[$r]} == all ]]; then
      if [[ ${has_phit[$r]} != 1 ]]; then
        say "cases.txt has no prose-hit case for rule ${r_id[$r]}, to pin its scope all"
        bad=1
      fi
    else
      pinned=0
      if [[ ${has_pmiss[$r]} == 1 ]]; then
        hits=$(rule_hits "$r" "$tmp/case.norm.prose" 0) || die "a tool failed on the cases of rule ${r_id[$r]}"
        hits=" $(printf '%s' "$hits" | tr '\n' ' ') "
        k=0
        while read -r n kind; do
          k=$((k + 1))
          [[ $kind == prose-miss && $hits == *" $k "* ]] && pinned=1
        done < "$tmp/case.prose.$r.from"
      fi
      if [[ $pinned != 1 ]]; then
        say "cases.txt has no prose-miss case that rule ${r_id[$r]} flags as code, to pin its scope code"
        bad=1
      fi
    fi
    # Each pass has a miss case that only it lets pass.
    for ((p = 0; p < n_pass; p++)); do
      [[ ${p_rule[$p]} == "$r" ]] || continue
      hits=$(rule_hits "$r" "$tmp/case.norm.code" 0) || die "a tool failed on the cases of rule ${r_id[$r]}"
      hits2=$(rule_hits "$r" "$tmp/case.norm.code" 0 "$p") || die "a tool failed on the cases of rule ${r_id[$r]}"
      hits=" $(printf '%s' "$hits" | tr '\n' ' ') " hits2=" $(printf '%s' "$hits2" | tr '\n' ' ') "
      pinned=0 k=0
      while read -r n kind; do
        k=$((k + 1))
        [[ $kind == miss && $hits2 == *" $k "* && $hits != *" $k "* ]] && pinned=1
      done < "$tmp/case.code.$r.from"
      if [[ $pinned != 1 ]]; then
        say "rules.txt:${p_n[$p]}: no miss case in cases.txt that only this pass lets pass"
        bad=1
      fi
    done
  done
  if [[ $bad != 0 ]]; then
    say "self-test failed: the rules or the cases are wrong, so no scan was made"
    exit 2
  fi
  say "self-test: $total cases passed"
}

load_rules
self_test
[[ $self_test_only == 1 ]] && exit 0

# ── the exceptions ───────────────────────────────────────────────────────────
exc_path=() exc_reason=() exc_line=() exc_count=()
n_exc=0
exc_bad=0
if [[ -n $exceptions_file ]]; then
  [[ -f $exceptions_file && -r $exceptions_file ]] || { esc "$exceptions_file"; die "cannot read the exceptions file $E"; }
  n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ $blank_re ]] && continue
    p= reason=
    read -r p reason <<< "$line"
    while [[ $p == ./* ]]; do p=${p#./}; done
    if [[ -z $p || $p == / ]]; then
      say "exceptions:$n: names no path"
      exc_bad=1
      continue
    fi
    esc "$p"
    if [[ -z $reason ]]; then
      say "exceptions:$n: $E has no reason; write the path, spaces, then why it stays as it is"
      exc_bad=1
      continue
    fi
    read -r -a words <<< "$reason"
    k=0
    for w in "${words[@]}"; do [[ $w == *[[:alpha:]]* ]] && k=$((k + 1)); done
    if [[ $k -lt $reason_words ]]; then
      say "exceptions:$n: the reason for $E is shorter than $reason_words words; say why it stays as it is"
      exc_bad=1
      continue
    fi
    # The log prints every reason: one that a rule flags, read as code, would
    # print a word of the rules.
    printf '%s\n' "$reason" > "$tmp/reason"
    normalize "$tmp/reason" "$tmp/reason.lines" "$tmp/reason.norm" || die "sed or tr failed on the exceptions"
    k=-1
    for ((r = 0; r < n_rules && k < 0; r++)); do
      hits=$(rule_hits "$r" "$tmp/reason.norm" 0) || die "a tool failed on the exceptions"
      [[ -n $hits ]] && k=$r
    done
    if [[ $k -ge 0 ]]; then
      say "exceptions:$n: the reason for $E holds a word that rule ${r_id[$k]} flags; reword it, as the log prints every reason"
      exc_bad=1
      continue
    fi
    exc_path[$n_exc]=$p
    exc_reason[$n_exc]=$reason
    exc_line[$n_exc]=$n
    exc_count[$n_exc]=0
    n_exc=$((n_exc + 1))
  done < "$exceptions_file"
fi

# ── the files ────────────────────────────────────────────────────────────────
root_abs=$(cd "$root" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null) ||
  { esc "$root"; die "$E is not inside a git repository (or git failed)"; }
cd "$root_abs" || die "cannot enter the repository's top directory"
root_phys=$(pwd -P)

# This script's own directory, when it lies inside the repository checked:
# its files list what the rules ban.
self_prefix=
if [[ $here == "$root_phys"/* ]]; then
  self_prefix=${here#"$root_phys"/}/
fi

# Each entry: its mode, its object, its stage, a tab and its path.
git ls-files -s -z > "$tmp/files" || die "git ls-files failed"
files=() modes=()
prev=
while IFS= read -r -d '' rec; do
  f=${rec#*$'\t'}
  [[ $f == "$prev" ]] && continue # an unmerged path is listed once per stage
  files[${#files[@]}]=$f
  modes[${#modes[@]}]=${rec%% *}
  prev=$f
done < "$tmp/files"

scan=()
n_tracked=${#files[@]} n_excepted=0 n_self=0 n_binary=0 n_links=0 n_missing=0
for ((i = 0; i < n_tracked; i++)); do
  f=${files[$i]}
  left_out=0
  for ((k = 0; k < n_exc; k++)); do
    p=${exc_path[$k]}
    if [[ $p == */ ]]; then
      [[ $f == "$p"* ]] || continue
    else
      [[ $f == "$p" ]] || continue
    fi
    exc_count[$k]=$((exc_count[$k] + 1))
    left_out=1
  done
  if [[ $left_out == 1 ]]; then
    n_excepted=$((n_excepted + 1))
    continue
  fi
  if [[ -n $self_prefix && $f == "$self_prefix"* ]]; then
    n_self=$((n_self + 1))
    continue
  fi
  case ${modes[$i]} in
    120000|160000) n_links=$((n_links + 1)); continue ;; # a symbolic link or a submodule
  esac
  if [[ ! -f ./$f || -L ./$f ]]; then
    esc "$f"
    say "$E: tracked, but not a file in the working tree"
    n_missing=$((n_missing + 1))
    continue
  fi
  [[ -r ./$f ]] || { esc "$f"; die "cannot read $E"; }
  # A NUL byte anywhere makes the file binary. wc reads all that tr passes
  # it, so neither stops early; the statuses of both are checked.
  nuls=($(tr -dc '\000' < "./$f" | wc -c; echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}"))
  [[ ${#nuls[@]} -eq 3 && ${nuls[1]} == 0 && ${nuls[2]} == 0 ]] || { esc "$f"; die "tr or wc failed on $E"; }
  if [[ ${nuls[0]} -gt 0 ]]; then
    n_binary=$((n_binary + 1))
    continue
  fi
  scan[${#scan[@]}]=./$f
done

for ((k = 0; k < n_exc; k++)); do
  if [[ ${exc_count[$k]} -eq 0 ]]; then
    esc "${exc_path[$k]}"
    if [[ ${exc_path[$k]} == */ ]]; then
      say "exceptions:${exc_line[$k]}: $E matches no tracked file; remove the exception"
    else
      say "exceptions:${exc_line[$k]}: $E matches no tracked file; remove the exception (a directory ends in /)"
    fi
    exc_bad=1
  fi
done
if [[ $exc_bad != 0 ]]; then
  say "the exceptions are wrong, so no scan was made"
  exit 2
fi
if [[ $n_missing -gt 0 ]]; then
  say "$(count "$n_missing" "tracked file") not in the working tree (deleted, replaced, or left out by a sparse checkout): the check reads the working tree, so no scan was made"
  exit 2
fi

for ((k = 0; k < n_exc; k++)); do
  esc "${exc_path[$k]}"
  p=$E
  esc "${exc_reason[$k]}"
  say "leaves out $p ($(count "${exc_count[$k]}" file)): $E"
done
if [[ $n_self -gt 0 ]]; then
  esc "$self_prefix"
  say "leaves out $E ($(count "$n_self" file)): lists what it bans"
fi
say "$(count "$n_tracked" "tracked file"): ${#scan[@]} read, $n_binary binary, $((n_excepted + n_self)) left out, $n_links links or submodules"
if [[ ${#scan[@]} -eq 0 ]]; then
  say "no tracked text file was read, so nothing can be called clean"
  exit 2
fi

# grep_over <output file> <grep option>...: grep over every file to read, a
# chunk of files at a time. Returns 2 when grep fails.
grep_over() {
  local out=$1 i st
  shift
  : > "$out"
  for ((i = 0; i < ${#scan[@]}; i += chunk)); do
    grep "$@" -- "${scan[@]:i:chunk}" >> "$out"
    st=$?
    [[ $st -le 1 ]] || return 2
  done
  return 0
}

# A first pass per rule finds the files worth a closer look: any of the
# rule's words anywhere in a line, whatever its case, a ? after a bracket
# read as *. In a file of ASCII or UTF-8 text a word a rule flags is spelled
# by the file's own letters, so the pass finds every file the rule flags.
# The lists keep the order of scan, so one index per list walks them.
cand=() c_at=() c_end=()
for ((r = 0; r < n_rules; r++)); do
  union=
  for ((l = 0; l < n_lines; l++)); do
    [[ ${l_rule[$l]} == "$r" ]] || continue
    union="$union${union:+|}(${l_words[$l]//]\?/]*})"
  done
  grep_over "$tmp/candidates" -l -a -i -E --null -e "$union" || die "grep failed on the first pass"
  c_at[$r]=${#cand[@]}
  while IFS= read -r -d '' f; do cand[${#cand[@]}]=$f; done < "$tmp/candidates"
  c_end[$r]=${#cand[@]}
done
grep_over "$tmp/marker-files" -l -a -F --null -e "$marker" || die "grep failed looking for the marker"
mfiles=()
while IFS= read -r -d '' f; do mfiles[${#mfiles[@]}]=$f; done < "$tmp/marker-files"

findings=0 files_found=0 n_marked=0 n_long=0
for ((r = 0; r < n_rules; r++)); do per_rule[$r]=0; done
: > "$tmp/log.marker"
: > "$tmp/log.found"
mi=0
for ((i = 0; i < ${#scan[@]}; i++)); do
  f=${scan[$i]}
  is_cand=0 is_marked=0
  for ((r = 0; r < n_rules; r++)); do
    c_has[$r]=0
    k=${c_at[$r]}
    if [[ $k -lt ${c_end[$r]} && ${cand[$k]} == "$f" ]]; then
      c_has[$r]=1 is_cand=1
      c_at[$r]=$((k + 1))
    fi
  done
  if [[ $mi -lt ${#mfiles[@]} && ${mfiles[$mi]} == "$f" ]]; then is_marked=1; mi=$((mi + 1)); fi
  [[ $is_cand == 1 || $is_marked == 1 ]] || continue
  esc "${f#./}"
  name=$E
  if [[ $is_cand == 1 ]]; then
    normalize "$f" "$tmp/lines" "$tmp/norm" || die "sed or tr failed on $name"
  else
    normalize "$f" "$tmp/lines" || die "sed or tr failed on $name"
  fi
  MARKED=' ' LONG=' '
  if [[ $is_marked == 1 ]]; then
    markers "$tmp/lines" || die "grep or cut failed on $name"
    for n in $MARKED; do
      n_marked=$((n_marked + 1))
      if allowed "$n"; then
        say "$name:$n: carries the marker, so no rule reads the line" >> "$tmp/log.marker"
      else
        n_long=$((n_long + 1))
        say "$name:$n: carries the marker on a line of more than $long_line bytes, so the marker allows nothing" >> "$tmp/log.marker"
      fi
    done
  fi
  [[ $is_cand == 1 ]] || continue
  lower "${f##*/}"
  b=$LOW
  is_prose=0
  case $b in
    cmakelists.txt|*requirements*.txt|*constraints*.txt) ;;
    readme|license|licence|copying|notice|changelog|changes|history|news|authors|contributors|contributing|code_of_conduct|security|support|maintainers|governance|patents|credits|thanks|unlicense|copyright) is_prose=1 ;;
    *.md|*.markdown|*.mdown|*.mkd|*.mkdn|*.mdx|*.rst|*.txt|*.text|*.adoc|*.asciidoc|*.org|*.rdoc|*.pod|*.tex|*.textile|*.wiki|*.license) is_prose=1 ;;
    license-*|licence-*|copying-*) [[ $b == *.* ]] || is_prose=1 ;;
  esac
  : > "$tmp/found"
  for ((r = 0; r < n_rules; r++)); do
    [[ ${c_has[$r]} == 1 ]] || continue
    rule_hits "$r" "$tmp/norm" "$is_prose" > "$tmp/nums" || die "a tool failed on $name"
    while read -r n; do
      allowed "$n" && continue
      printf '%s %s\n' "$n" "$r" >> "$tmp/found"
    done < "$tmp/nums"
  done
  if [[ -s $tmp/found ]]; then
    files_found=$((files_found + 1))
    sort -s -n -k1,1 "$tmp/found" > "$tmp/found.sorted" || die "sort failed"
    while read -r n r; do
      say "$name:$n: ${r_id[$r]}" >> "$tmp/log.found"
      per_rule[$r]=$((per_rule[$r] + 1))
      findings=$((findings + 1))
    done < "$tmp/found.sorted"
  fi
done
# The walk met every file the first passes named: a grep that names a file
# in another way than it was given must not leave that file unread.
for ((r = 0; r < n_rules; r++)); do
  [[ ${c_at[$r]} == "${c_end[$r]}" ]] ||
    die "grep -l named a file other than as it was given, so the files it named were not all read and nothing can be called clean"
done
[[ $mi == "${#mfiles[@]}" ]] ||
  die "grep -l named a file other than as it was given, so the lines that carry the marker are not all known and nothing can be called clean"

if [[ $n_marked -eq 0 ]]; then
  say "no line carries $marker"
elif [[ $n_marked -eq 1 ]]; then
  say "1 line carries $marker:"
else
  say "$n_marked lines carry $marker:"
fi
cat "$tmp/log.marker" "$tmp/log.found" || die "cat failed"

if [[ $findings -eq 0 ]]; then
  say "clean"
  exit 0
fi
summary=
for ((r = 0; r < n_rules; r++)); do
  summary="$summary${summary:+, }${r_id[$r]} ${per_rule[$r]}"
done
say "$(count "$findings" finding) in $(count "$files_found" file) ($summary)"
say "Each finding names a file, a line and the rule the line breaks; the rules"
say "and their words are in neutrality/rules.txt of zaentrum/.github. Reword the"
say "line. Where a line has to name the word (a test that asserts it is absent,"
say "a sentence that says what the project refuses), add $marker"
say "to that line. A path that has to stay as it is goes into the exceptions,"
say "with its reason."
exit 1

#!/usr/bin/env bash
# Markdown for run.sh's results: a table, then each failure's log, cut.
#
#   ecosystem/report.sh <work-dir> >report.md
set -euo pipefail

work="$1"
results="$work/results.tsv"

# <package>'s <stage> result: ok, fail, or nothing (not reached).
result() {
  awk -F '\t' -v p="$1" -v s="$2" '$1 == p && $2 == s { print $3 }' "$results"
}

# How many packages' <stage> was ok.
count() {
  awk -F '\t' -v s="$1" '$2 == s && $3 == "ok"' "$results" | wc -l
}

packages=()
while read -r name _; do packages+=("$name"); done <"$work/selected.txt"

echo "## Cross-compiling opam packages with dune pkg"
echo
echo "Each package's libraries, linked (\`-linkall\`) into an executable that runs on the"
echo "target. ✅ built and ran, ⚠️ built but didn't run, ❌ failed; · not reached."
echo
echo "| | packages |"
echo "|---|---|"
echo "| tested | ${#packages[@]} |"
echo "| locked | $(count lock) |"
echo "| built natively | $(count native) |"
for target in $TARGETS; do
  echo "| built for $target | $(count "build:$target") |"
  echo "| ran on $target | $(count "run:$target") |"
done
echo

header="| package | lock | native |"
rule="|---|---|---|"
for target in $TARGETS; do
  header="$header $target |"
  rule="$rule---|"
done
echo "$header"
echo "$rule"
for package in "${packages[@]}"; do
  row="| $package |"
  for stage in lock native; do
    case "$(result "$package" "$stage")" in
      ok) row="$row ✅ |" ;;
      fail) row="$row ❌ |" ;;
      *) row="$row · |" ;;
    esac
  done
  for target in $TARGETS; do
    case "$(result "$package" "build:$target")/$(result "$package" "run:$target")" in
      ok/ok) row="$row ✅ |" ;;
      ok/fail) row="$row ⚠️ |" ;;
      fail/*) row="$row ❌ |" ;;
      *) row="$row · |" ;;
    esac
  done
  echo "$row"
done

echo
echo "### Failures"
awk -F '\t' '$3 == "fail" { print $1 "\t" $2 }' "$results" | while IFS=$'\t' read -r package stage; do
  echo
  echo "<details><summary>$package: $stage</summary>"
  echo
  echo '```'
  tail -n 40 "$work/$package/${stage/:/-}.log"
  echo '```'
  echo "</details>"
done

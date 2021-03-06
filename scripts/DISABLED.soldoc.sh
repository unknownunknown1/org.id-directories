#!/usr/bin/env bash

# Exit script as soon as a command fails.
set -o errexit

# Executes cleanup function at script exit.
trap cleanup EXIT

cleanup() {
  rm -rf .flattened
}

rm -rf .flattened
mkdir .flattened
rm -f docs/*.md

exclude=( "Migrations.sol", "EnhancedAppealableArbitrator.sol", "CentralizedArbitrator.sol", "DirectoryUpgradeability.sol", "DirectoryIndexUpgradeability.sol" )

for f in $(find contracts -name *.sol)
  do if [[ "${exclude[*]}" != *`basename $f`* ]]; then
    file=`basename $f`
    filename="${file%.*}"
    npx truffle-flattener "$f" > .flattened/"$file"
    npx solmd .flattened/"$file" --dest docs/"$filename".md
  fi
done

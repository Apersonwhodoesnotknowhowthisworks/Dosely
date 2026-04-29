#!/usr/bin/env bash
# Deploys firestore.rules to the live Firebase project.
#
# Run from any directory; the script cd's to the repo root before
# invoking the Firebase CLI so the relative paths in firebase.json
# resolve correctly.
#
# Requires:
#   - firebase-cli installed (`brew install firebase-cli`)
#   - `firebase login` completed at least once
#   - the repo's Firebase project set as the active project
#     (`firebase use <project-id>` once)
#
# This pushes ONLY the rules file. Indexes and emulator config are
# untouched. The CLI prints a diff and prompts before publishing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v firebase >/dev/null 2>&1; then
  echo "firebase CLI not found. Install with: brew install firebase-cli" >&2
  exit 1
fi

echo "Deploying firestore.rules from $REPO_ROOT ..."
firebase deploy --only firestore:rules
echo "Done."

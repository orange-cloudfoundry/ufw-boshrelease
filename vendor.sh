#!/bin/bash
set -e -o pipefail

# vendir has no retry/timeout for http sources; upstream hosting (Ubuntu
# archive CDN) is occasionally flaky, so retry the whole sync.
attempt=1
until vendir sync -f vendir.yml --lock-file vendir.lock; do
  if [ "$attempt" -ge 3 ]; then
    echo "vendor.sh: vendir sync failed after $attempt attempts" >&2
    exit 1
  fi
  echo "vendor.sh: attempt $attempt failed, retrying in 5s..." >&2
  attempt=$((attempt + 1))
  sleep 5
done

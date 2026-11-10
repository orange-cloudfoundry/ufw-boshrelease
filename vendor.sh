#!/bin/bash
set -e -o pipefail

vendir sync -f vendir.yml --lock-file vendir.lock

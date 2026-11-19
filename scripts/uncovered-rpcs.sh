#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

# uncovered-rpcs.sh: print the RPCs in the generated bindings (src/gen) that
# no curated SDK code under src calls, one "Service.Method" per line. Tests
# and the bindings don't count; client.raw reaches every RPC anyway.
#
# protoc-gen-es writes each method as
#   * @generated from rpc openshell.v1.OpenShell.CreateSandbox
#   */
#  createSandbox: {
# and Connect clients call it as client.createSandbox(...).
set -euo pipefail

awk '
  /@generated from rpc / { n = split($NF, p, "."); service = p[n - 1]; want = 1; next }
  want && /^  [A-Za-z0-9_]+: \{$/ { sub(/^  /, ""); sub(/: \{$/, ""); print service " " $0; want = 0 }
  ' src/gen/*_pb.ts | sort -u |
  while read -r service method; do
    grep -rqE "\.${method}\(" src --include='*.ts' --exclude-dir=gen --exclude='*.test.ts' ||
      echo "${service}.${method}"
  done

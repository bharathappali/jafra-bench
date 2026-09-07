#!/usr/bin/env bash
# Entrypoint for the Renaissance benchmark container.
# Uses JAVA_OPTS for heap/tuning so Jafra can inject into JAVA_TOOL_OPTIONS.
set -euo pipefail

JAR="${RENAISSANCE_JAR:-/opt/renaissance/renaissance.jar}"
BENCHMARKS="${BENCHMARKS:-}"
RENAISSANCE_ARGS="${RENAISSANCE_ARGS:--r 1 --scratch-base /tmp/renaissance-scratch}"
JAVA_OPTS="${JAVA_OPTS:--Xms512m -Xmx1536m}"

mkdir -p /tmp/renaissance-scratch

echo "=== Renaissance container ==="
echo "JAR:          ${JAR}"
echo "BENCHMARKS:   ${BENCHMARKS:-<none>}"
echo "RENAISSANCE_ARGS: ${RENAISSANCE_ARGS}"
echo "JAVA_OPTS:    ${JAVA_OPTS}"
echo "JAVA_TOOL_OPTIONS: ${JAVA_TOOL_OPTIONS:-<unset>}"
echo "============================="

# Intentional word-splitting for JVM / harness flags from env strings.
# shellcheck disable=SC2086
if [[ -n "${BENCHMARKS}" ]]; then
  exec java ${JAVA_OPTS} -jar "${JAR}" ${RENAISSANCE_ARGS} ${BENCHMARKS} "$@"
else
  exec java ${JAVA_OPTS} -jar "${JAR}" "$@"
fi

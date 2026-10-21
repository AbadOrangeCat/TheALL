#!/bin/bash
# Terminate the running TheAll Debug app.
set -e

echo "==> Killing running TheAll…"
pkill -f "Debug/TheAll.app" 2>/dev/null || true
sleep 1

if pgrep -lf "Debug/TheAll.app" >/dev/null; then
  echo "!! TheAll still running, sending SIGKILL"
  pkill -9 -f "Debug/TheAll.app" 2>/dev/null || true
  sleep 1
fi

if pgrep -lf "Debug/TheAll.app" >/dev/null; then
  echo "!! failed to terminate TheAll" >&2
  exit 1
else
  echo "==> TheAll terminated"
fi

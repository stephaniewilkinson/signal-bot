#!/bin/bash
set -e

# Seed signal-cli data to persistent disk on first boot
if [ ! -f /data/signal-cli/accounts.json ] && [ -f /app/signal-cli-data/accounts.json ]; then
  echo "==> Seeding signal-cli data to persistent disk..."
  cp -r /app/signal-cli-data/* /data/signal-cli/
fi

echo "==> Running Ecto migrations..."
/app/bin/yonderbook_clubs eval "YonderbookClubs.Release.migrate()"

echo "==> Starting signal-cli daemon..."
export JAVA_OPTS="${JAVA_OPTS:--Xmx256m}"
signal-cli --config /data/signal-cli \
  daemon --tcp localhost:7583 &

SIGNAL_CLI_PID=$!

echo "==> Waiting for signal-cli on port 7583..."
for i in $(seq 1 30); do
  if nc -z localhost 7583 2>/dev/null; then
    echo "==> signal-cli is ready."
    break
  fi
  if ! kill -0 $SIGNAL_CLI_PID 2>/dev/null; then
    echo "==> signal-cli exited unexpectedly."
    exit 1
  fi
  sleep 2
done

if ! nc -z localhost 7583 2>/dev/null; then
  echo "==> signal-cli failed to start within 60 seconds."
  exit 1
fi

echo "==> Starting YonderbookClubs..."
exec /app/bin/yonderbook_clubs start

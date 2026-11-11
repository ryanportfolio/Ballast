#!/usr/bin/env bash
# Start (or restart) the Ballast dev processes inside the Codespace, detached
# from the SSH session so they keep running after `gh codespace ssh` exits.
# Sure's bin/dev can't be used detached: its Tailwind watcher exits when stdin
# closes, and foreman then stops every process.
#
# Run from a local terminal:
#   gh codespace ssh -c <name> -- bash /workspace/scripts/codespace-dev.sh
# Logs: /tmp/ballast-{web,worker,css}.log inside the Codespace.
set -euo pipefail
cd /workspace

pkill -f '[p]uma' || true
pkill -f '[s]idekiq' || true
pkill -f '[t]ailwindcss' || true
sleep 2
rm -f tmp/pids/server.pid

export PORT="${PORT:-3000}"
setsid nohup bin/rails server -b 0.0.0.0 -p "$PORT" > /tmp/ballast-web.log 2>&1 < /dev/null &
setsid nohup bundle exec sidekiq > /tmp/ballast-worker.log 2>&1 < /dev/null &
setsid nohup bin/rails 'tailwindcss:watch[always]' > /tmp/ballast-css.log 2>&1 < /dev/null &

for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/sessions/new" || true)
  if [ "$code" = 200 ]; then echo "Ballast is up on port $PORT"; exit 0; fi
  sleep 2
done
echo "Ballast did not answer on port $PORT; see /tmp/ballast-web.log" >&2
exit 1

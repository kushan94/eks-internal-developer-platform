#!/usr/bin/env bash
# Tests the Backstage launcher against a real Postgres in Docker, with a fake
# backend. See gitops/root/files/backstage-start.js and tests/backstage-start/.
# Needs Docker, Node 20 or later, and npm (for the pg module).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

name="backstage-start-test-$$"
trap 'docker rm -f "$name" > /dev/null 2>&1' EXIT
docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=test -p 127.0.0.1::5432 "${POSTGRES_IMAGE:-postgres:17-alpine}" > /dev/null || exit 1
port="$(docker port "$name" 5432/tcp | head -n 1 | sed 's/.*://')"
for _ in $(seq 1 30); do docker exec "$name" pg_isready -U postgres > /dev/null 2>&1 && break; sleep 1; done

# The launcher uses the pg module that is in the Backstage image. Here it is installed on its own.
mkdir -p .test/launcher-test
[ -d .test/launcher-test/node_modules/pg ] || npm install --prefix .test/launcher-test --silent --no-audit --no-fund pg || exit 1

NODE_PATH="$PWD/.test/launcher-test/node_modules" TEST_PGPORT="$port" node --test --test-timeout=45000 --test-reporter=spec tests/backstage-start/test.js

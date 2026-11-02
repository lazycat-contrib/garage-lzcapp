#!/bin/sh
set -eu

# The web UI reads its credentials from AUTH_USER_PASS as "<user>:<bcrypt hash>"
# (see backend/router/auth.go, which calls bcrypt.CompareHashAndPassword), and
# backend/middleware/auth.go skips authentication entirely when that variable is
# empty. YAML templating cannot compute bcrypt, so a small init container mints
# the hash with htpasswd and drops it in a shared volume; this script waits for
# that file and hands it to the server as an environment variable.

AUTH_FILE="${AUTH_FILE:-/var/lib/garage-auth/userauth}"

i=0
while [ "${i}" -lt 120 ]; do
  if [ -s "${AUTH_FILE}" ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if [ ! -s "${AUTH_FILE}" ]; then
  echo "webui: credentials file ${AUTH_FILE} never appeared -- refusing to start without authentication" >&2
  exit 1
fi

# The file holds "<user>:<hash>"; strip any trailing newline only.
AUTH_USER_PASS="$(tr -d '\r\n' < "${AUTH_FILE}")"
case "${AUTH_USER_PASS}" in
  *:*) ;;
  *) echo "webui: malformed credentials entry" >&2; exit 1 ;;
esac
export AUTH_USER_PASS

exec /main

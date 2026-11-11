#!/bin/bash
# Runs in an SDK checkout. Adds services/selenium-chrome.yml of that checkout
# to docker-compose.yml the way "make addservice" does, with a plain httpd as
# the "apache" service and an idle container as the "php" service. Then opens
# a Chrome session through WebDriver and loads http://localhost.local/, which
# the service file links to apache. Prints "key<TAB>value" lines, exits 1 on a
# failed check.

set -u
fail=0
out() { printf '%s\t%s\n' "$1" "$2"; }
bad() { printf 'FAIL\t%s\n' "$1"; fail=1; }

make setup > /dev/null
mkdir -p source
printf '  apache:\n    image: httpd:2.4-alpine\n\n  php:\n    image: alpine:3\n    command: sleep infinity\n\n' >> docker-compose.yml
make file=services/selenium-chrome.yml addservice > /dev/null

out host_arch "$(uname -m)"
out selenium_platform_in_compose "$(docker compose config --format json | jq -r '.services.selenium.platform // "not set"')"

docker compose up -d > /dev/null 2>&1

# The service file gives the grid 300 seconds to start, so does this check.
start=$(date +%s)
ready=false
while [ $(( $(date +%s) - start )) -lt 300 ]; do
  ready=$(curl -s -m 5 http://127.0.0.1:4444/status | jq -r '.value.ready' 2>/dev/null)
  [ "$ready" = "true" ] && break
  sleep 2
done
out selenium_ready "${ready:-false} after $(( $(date +%s) - start ))s"
[ "$ready" = "true" ] || bad "grid is not ready"

out selenium_state "$(docker compose ps -a --format '{{.Service}} {{.State}}' | awk '$1 == "selenium" {print $2}')"
out selenium_arch "$(docker compose exec -T selenium uname -m 2>/dev/null | tr -d '\r')"

wd() { curl -s -m 120 -H 'Content-Type: application/json' "$@"; }
caps='{"capabilities":{"alwaysMatch":{"browserName":"chrome","goog:chromeOptions":{"args":["--headless=new","--no-sandbox","--disable-dev-shm-usage"]}}}}'
session=$(wd -X POST http://127.0.0.1:4444/session -d "$caps")
id=$(printf '%s' "$session" | jq -r '.value.sessionId // empty' 2>/dev/null)
if [ -z "$id" ]; then
  bad "selenium did not open a session: $(printf '%s' "$session" | tr '\n' ' ' | cut -c1-300)"
else
  out selenium_browser "$(printf '%s' "$session" | jq -r '.value.capabilities | "\(.browserName) \(.browserVersion)"')"
  wd -X POST "http://127.0.0.1:4444/session/$id/url" -d '{"url":"http://localhost.local/"}' > /dev/null
  title=$(wd "http://127.0.0.1:4444/session/$id/title" | jq -r '.value')
  text=$(wd -X POST "http://127.0.0.1:4444/session/$id/execute/sync" -d '{"script":"return document.body.innerText","args":[]}' | jq -r '.value' | tr -d '\n')
  wd -X DELETE "http://127.0.0.1:4444/session/$id" > /dev/null
  out selenium_page "title=[$title] text=[$text]"
  case "$text" in *"It works!"*) ;; *) bad "the browser did not load the page from apache" ;; esac
fi

[ "$fail" = "0" ] || out selenium_log "$(docker compose logs --no-log-prefix --tail 5 selenium 2>&1 | tr '\n' ' ' | cut -c1-600)"
if [ "$fail" = "0" ]; then out result PASS; else out result FAIL; fi
exit $fail

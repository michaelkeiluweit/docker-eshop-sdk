#!/bin/bash
# Checks a shop that a recipe has just installed in the current SDK checkout.
# Prints one "key<TAB>value" line per measurement and exits 1 if a check fails.
# All HTTP requests are sent from inside the compose network, so the result
# does not depend on the ports published to the host.

set -u
fail=0
out() { printf '%s\t%s\n' "$1" "$2"; }
bad() { printf 'FAIL\t%s\n' "$1"; fail=1; }
# The selenium service is outside the change under test when SELENIUM_BLOCKING=0.
sbad() { if [ "${SELENIUM_BLOCKING:-1}" = "0" ]; then printf "NOTE\t%s\n" "$1"; else bad "$1"; fi; }

out host_arch "$(uname -m)"
out docker_arch "$(docker version --format '{{.Server.Arch}}')"

while read -r service state; do
  arch=$(docker compose exec -T "$service" uname -m < /dev/null 2>/dev/null | tr -d '\r')
  out "service_$service" "${arch:-unknown} $state"
  [ "$state" = "running" ] || bad "service $service is $state"
done < <(docker compose ps -a --format '{{.Service}} {{.State}}' | sort)

php() { docker compose exec -T php "$@"; }

out php_version "$(php php -r 'echo PHP_VERSION, " ", php_uname("m");')"
out mysql_version "$(php php -r '$p = new PDO("mysql:host=mysql;dbname=example", "root", "root"); echo $p->query("select concat(version(), \" \", @@version_compile_machine)")->fetchColumn();')"
out shop_tables "$(php php -r '$p = new PDO("mysql:host=mysql;dbname=example", "root", "root"); echo $p->query("select count(*) from information_schema.tables where table_schema = \"example\"")->fetchColumn();')"
out shop_articles "$(php php -r '$p = new PDO("mysql:host=mysql;dbname=example", "root", "root"); echo $p->query("select count(*) from oxarticles")->fetchColumn();')"

page() {
  name=$1
  url=$2
  code=$(php curl -s -L -o /tmp/arch-check-page -w '%{http_code}' "$url")
  title=$(php sh -c "tr '\n' ' ' < /tmp/arch-check-page | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p'" | sed 's/^ *//; s/ *$//')
  size=$(php sh -c 'wc -c < /tmp/arch-check-page' | tr -d ' ')
  out "http_$name" "$code ${size}b title=[$title]"
  [ "$code" = "200" ] || bad "$name answers $code"
  [ -n "$title" ] || bad "$name has no title"
  if php grep -q -i -E 'fatal error|uncaught|stack trace' /tmp/arch-check-page; then
    bad "$name contains an error message"
  fi
}

page start http://localhost.local/
page admin http://localhost.local/admin/

if docker compose ps --services | grep -q '^selenium$'; then
  wd() { php curl -s -H 'Content-Type: application/json' "$@"; }
  field() { python3 -I -c 'import json, sys
value = json.load(sys.stdin).get("value")
for key in sys.argv[1:]:
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else value)' "$@"; }

  caps='{"capabilities":{"alwaysMatch":{"browserName":"chrome","goog:chromeOptions":{"args":["--headless=new","--no-sandbox","--disable-dev-shm-usage"]}}}}'
  session=$(wd -X POST http://selenium:4444/session -d "$caps")
  id=$(printf '%s' "$session" | field sessionId)
  if [ -z "$id" ]; then
    sbad "selenium did not open a session"
  else
    out selenium_browser "$(printf '%s' "$session" | field capabilities browserName) $(printf '%s' "$session" | field capabilities browserVersion)"
    wd -X POST "http://selenium:4444/session/$id/url" -d '{"url":"http://localhost.local/"}' > /dev/null
    title=$(wd "http://selenium:4444/session/$id/title" | field)
    links=$(wd -X POST "http://selenium:4444/session/$id/execute/sync" -d '{"script":"return document.querySelectorAll(\"a\").length","args":[]}' | field)
    wd -X DELETE "http://selenium:4444/session/$id" > /dev/null
    out selenium_start "title=[$title] links=$links"
    [ -n "$title" ] || sbad "selenium got no title from the start page"
    [ "${links:-0}" -gt 0 ] 2>/dev/null || sbad "selenium found no links on the start page"
  fi
fi

if [ "$fail" = "0" ]; then out result PASS; else out result FAIL; fi
exit $fail

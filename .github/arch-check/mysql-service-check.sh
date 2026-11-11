#!/bin/bash
# Runs in an SDK checkout. Adds services/mysql.yml of that checkout to
# docker-compose.yml the way "make addservice" does and checks which platform
# the mysql service resolves to and that the database starts and answers.
# Prints "key<TAB>value" lines, exits 1 on a failed check.

set -u
fail=0
out() { printf '%s\t%s\n' "$1" "$2"; }
bad() { printf 'FAIL\t%s\n' "$1"; fail=1; }
platform() { docker compose config --format json | jq -r '.services.mysql.platform // "not set"'; }

make setup > /dev/null
make file=services/mysql.yml addservice > /dev/null

out host_arch "$(uname -m)"
out env_dist_line "$(grep '^MYSQL_PLATFORM' .env.dist || echo 'no MYSQL_PLATFORM in .env.dist')"

fresh=$(platform)
out platform_with_fresh_env "$fresh"
[ "$fresh" = "linux/amd64" ] || bad "a fresh .env resolves to $fresh"

# An .env that was created before the variable existed.
cp .env .env.fresh
grep -v '^MYSQL_PLATFORM' .env.fresh > .env
old=$(platform)
out platform_with_old_env "$old"
[ "$old" = "linux/amd64" ] || bad "an .env without the variable resolves to $old"

# Not a pass criterion: master ignores the variable, the branch follows it.
echo 'MYSQL_PLATFORM=linux/arm64' >> .env
out platform_with_arm64_in_env "$(platform)"
cp .env.fresh .env

docker compose up -d > /dev/null 2>&1
start=$(date +%s)
health=starting
while [ $(( $(date +%s) - start )) -lt 300 ]; do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -aq mysql)" 2>/dev/null)
  [ "$health" = "healthy" ] && break
  sleep 2
done
out mysql_health "${health:-missing} after $(( $(date +%s) - start ))s"
[ "$health" = "healthy" ] || bad "mysql is ${health:-missing}"

out mysql_arch "$(docker compose exec -T mysql uname -m 2>/dev/null | tr -d '\r')"
version=$(docker compose exec -T mysql mysql -uroot -proot -N -e 'select concat(version(), " ", @@version_compile_machine)' 2>/dev/null | tr -d '\r')
out mysql_version "$version"
[ -n "$version" ] || bad "mysql does not answer a query"

[ "$fail" = "0" ] || out mysql_log "$(docker compose logs --no-log-prefix --tail 5 mysql 2>&1 | tr '\n' ' ' | cut -c1-600)"
if [ "$fail" = "0" ]; then out result PASS; else out result FAIL; fi
exit $fail

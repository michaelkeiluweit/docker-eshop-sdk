#!/bin/bash
# Runs in an SDK checkout. Adds services/nginx-rp.yml of that checkout to
# docker-compose.yml the way "make addservice" does, puts a plain httpd behind
# it as the "apache" service and checks that nginx proxies a request and runs
# Lua. Prints "key<TAB>value" lines, exits 1 on a failed check.

set -u
fail=0
out() { printf '%s\t%s\n' "$1" "$2"; }
bad() { printf 'FAIL\t%s\n' "$1"; fail=1; }

config=$PWD/nginx-check-config
mkdir -p "$config"
cat > "$config/nginx.conf" <<'CONF'
server {
    listen 80 default_server;
    location /lua {
        default_type text/plain;
        content_by_lua_block { ngx.say("lua " .. _VERSION .. " " .. (jit and (jit.version .. " " .. jit.arch) or "no jit")) }
    }
    location / {
        proxy_pass http://apache:80;
        proxy_set_header Host $host;
    }
}
CONF
echo '-- placeholder for the mount of the service file' > "$config/ClearCache.lua"

make setup > /dev/null
sed -i "s|^NGINX_SERVER_CONFIG_DIR=.*|NGINX_SERVER_CONFIG_DIR=$config|; s|^PORT_SHOP=.*|PORT_SHOP=8000|" .env
printf '  apache:\n    image: httpd:2.4-alpine\n\n' >> docker-compose.yml
make file=services/nginx-rp.yml addservice > /dev/null

out host_arch "$(uname -m)"
out nginx_platform_in_compose "$(docker compose config --format json | jq -r '.services.nginx.platform // "not set"')"

docker compose up -d > /dev/null 2>&1
sleep 5

state=$(docker compose ps -a --format '{{.Service}} {{.State}}' | awk '$1 == "nginx" {print $2}')
out nginx_state "${state:-missing}"
[ "$state" = "running" ] || bad "nginx is ${state:-missing}"
out nginx_arch "$(docker compose exec -T nginx uname -m 2>/dev/null | tr -d '\r')"
out nginx_version "$(docker compose exec -T nginx nginx -v 2>&1 | tr -d '\r')"

status=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/)
out proxy_status "$status"
[ "$status" = "200" ] || bad "proxied request answers $status"

# The image ships its own default page, so the status alone proves nothing.
body=$(curl -s http://localhost:8000/ | tr -d '\n')
out proxy_body "$body"
case "$body" in *"It works!"*) ;; *) bad "answer does not come from the backend" ;; esac

lua=$(curl -s http://localhost:8000/lua | tr -d '\n' | cut -c1-120)
out lua "$lua"
case "$lua" in lua*) ;; *) bad "Lua location does not answer" ;; esac

[ "$fail" = "0" ] || out nginx_log "$(docker compose logs --no-log-prefix --tail 3 nginx 2>&1 | tr '\n' ' ')"
if [ "$fail" = "0" ]; then out result PASS; else out result FAIL; fi
exit $fail

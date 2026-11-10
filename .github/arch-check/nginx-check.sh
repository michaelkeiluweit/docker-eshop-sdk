#!/bin/bash
# Starts oxidesales/oxideshop-docker-nginx on the platform of the host, the
# way services/nginx-rp.yml does without a platform pin, and checks that it
# proxies a request and runs Lua. Prints "key<TAB>value" lines, exits 1 on a
# failed check.

set -u
image=oxidesales/oxideshop-docker-nginx:${NGINX_VERSION:-1.24}
work=$(mktemp -d)
net=nginx-arch-check
fail=0
out() { printf '%s\t%s\n' "$1" "$2"; }
bad() { printf 'FAIL\t%s\n' "$1"; fail=1; }
cleanup() {
  docker rm -f nginx-arch-check-proxy nginx-arch-check-backend > /dev/null 2>&1
  docker network rm $net > /dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

cat > "$work/nginx.conf" <<'EOF'
server {
    listen 80 default_server;
    location /lua {
        default_type text/plain;
        content_by_lua_block { ngx.say("lua " .. _VERSION .. " " .. (jit and (jit.version .. " " .. jit.arch) or "no jit")) }
    }
    location / {
        proxy_pass http://nginx-arch-check-backend:80;
        proxy_set_header Host $host;
    }
}
EOF

docker network create $net > /dev/null
docker run -d --name nginx-arch-check-backend --network $net httpd:2.4-alpine > /dev/null
docker run -d --name nginx-arch-check-proxy --network $net \
  -v "$work/nginx.conf:/etc/nginx/sites-enabled/default:ro" ${NGINX_PLATFORM:+--platform $NGINX_PLATFORM} "$image" > /dev/null

out host_arch "$(uname -m)"
out nginx_arch "$(docker exec nginx-arch-check-proxy uname -m)"
out nginx_version "$(docker exec nginx-arch-check-proxy nginx -v 2>&1)"
out nginx_modules "$(docker exec nginx-arch-check-proxy sh -c 'nginx -V 2>&1; ls /etc/nginx/modules-enabled 2>/dev/null' | tr ' ' '\n' | grep -E -i 'lua|ndk' | sort -u | tr '\n' ' ')"

sleep 3
state=$(docker inspect -f '{{.State.Status}}' nginx-arch-check-proxy)
out nginx_state "$state"
[ "$state" = "running" ] || { bad "nginx is $state: $(docker logs nginx-arch-check-proxy 2>&1 | tail -3 | tr '\n' ' ')"; }

req() { docker run --rm --network $net curlimages/curl:latest -s -o /dev/null -w '%{http_code}' "$1"; }
body() { docker run --rm --network $net curlimages/curl:latest -s "$1"; }

proxied=$(req http://nginx-arch-check-proxy/)
out proxy_status "$proxied"
[ "$proxied" = "200" ] || bad "proxied request answers $proxied"

# The image ships its own default page, so the status alone proves nothing.
backend=$(body http://nginx-arch-check-proxy/ | tr -d '\n')
out proxy_body "$backend"
case "$backend" in *"It works!"*) ;; *) bad "answer does not come from the backend" ;; esac

lua=$(body http://nginx-arch-check-proxy/lua | tr -d '\n')
out lua "$lua"
case "$lua" in lua*) ;; *) bad "Lua location does not answer" ;; esac

if [ "$fail" = "0" ]; then out result PASS; else out result FAIL; fi
exit $fail

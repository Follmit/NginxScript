set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: Нет root доступа"
   exit 1
fi

echo "Обновление и установка пакетов"
apt-get update && apt-get upgrade -y
apt-get install -y curl wget git ufw fail2ban software-properties-common ca-certificates gnupg nginx
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "Установка Docker"
if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    echo "Docker уже установлен"
fi

echo "Конфигурирование NetworkSecurity"

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
echo "y" | ufw enable

cat << 'EOF' > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 600
bantime = 3600
EOF

systemctl restart fail2ban
systemctl enable fail2ban

echo "Конфигурирование Nginx"

cat << 'EOF' > /etc/nginx/conf.d/security.conf
server_tokens off;
client_max_body_size 16M;
client_body_buffer_size 128k;

client_body_timeout 10s;
client_header_timeout 10s;
keepalive_timeout 15s;
send_timeout 10s;

add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

limit_req_zone $binary_remote_addr zone=fastapi_limit:10m rate=15r/s;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;
EOF

TARGET_CONF="/etc/nginx/sites-available/fastapi.conf"

if [ -f "$TARGET_CONF" ]; then
    cp "$TARGET_CONF" "${TARGET_CONF}.bak_$(date +%Y%m%d_%H%M%S)"
fi

cat << 'EOF' > "$TARGET_CONF"
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    limit_req zone=fastapi_limit burst=20 nodelay;
    limit_conn conn_limit 20;

    limit_req_status 429;
    limit_conn_status 429;

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { log_not_found off; access_log off; }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

mkdir -p /etc/nginx/sites-enabled
ln -sf "$TARGET_CONF" /etc/nginx/sites-enabled/fastapi.conf
rm -f /etc/nginx/sites-enabled/default

echo "Проверка и перезапуск Nginx"
if nginx -t; then
    systemctl reload nginx
    echo "Конфигурирование завершено!"
else
    echo "Ошибка Конфигурирования"
    exit 1
fi

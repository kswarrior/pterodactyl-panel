#!/usr/bin/env bash
# =============================================================================
# KS Warrior - Powerful Pterodactyl Panel in SINGLE Docker Container (2026)
# Empty Ubuntu → full official bare-metal install inside → zero host pollution
# All-in-one: Panel + Nginx + MariaDB + Redis + Queue + Cron in one container
# Port 80 exposed | Fully automated after prompts
# =============================================================================

set -euo pipefail

INSTALL_DIR="$HOME/.ks/pterodactyl/panel"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\( {GREEN}KS Warrior presents: Pterodactyl Panel in ONE Docker container \){NC}"
echo "Everything runs inside → your host stays clean!"

# ────────────────────────────────────────────────
# Gather user input
# ────────────────────────────────────────────────
echo -e "\n\( {YELLOW}Panel URL (http://your-domain.com or http://your-server-ip): \){NC}"
read -r APP_URL
APP_URL="${APP_URL:-http://localhost}"

DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
ROOT_DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

echo -e "\n\( {YELLOW}Generated passwords (SAVE THEM!): \){NC}"
echo "MariaDB root password   : ${RED}\( ROOT_DB_PASS \){NC}"
echo "Panel DB password       : ${RED}\( DB_PASS \){NC}"

echo -e "\n\( {YELLOW}Admin details: \){NC}"
echo "Admin email? (default: admin@example.com)"
read -r ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

echo "Admin username? (default: admin)"
read -r ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

echo "Admin password? (min 8 chars)"
read -s ADMIN_PASS
echo ""

# ────────────────────────────────────────────────
# Launch empty Ubuntu container
# ────────────────────────────────────────────────
echo -e "\n\( {YELLOW}Starting empty Ubuntu container (name: ks-ptero-all-in-one)... \){NC}"
docker rm -f ks-ptero-all-in-one 2>/dev/null || true

docker run -d --name ks-ptero-all-in-one --restart unless-stopped \
  -p 80:80 \
  -e TZ=Asia/Kolkata \
  ubuntu:24.04 sleep infinity

sleep 6  # give container time to boot

# ────────────────────────────────────────────────
# Full installation inside container
# ────────────────────────────────────────────────
echo -e "\( {YELLOW}Installing Pterodactyl Panel + all services inside container... \){NC}"

docker exec -it ks-ptero-all-in-one bash -c "
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update && apt-get upgrade -y && apt-get install -y \
  software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release \
  nginx nginx-extras \
  php8.3 php8.3-{cli,gd,mysql,mbstring,bcmath,xml,curl,zip,fpm} \
  mariadb-server redis-server tar unzip git composer

# ─────── MariaDB setup ───────
mysqld_safe --user=mysql --skip-networking --socket=/var/run/mysqld/mysqld.sock &
sleep 10

until mysqladmin ping --silent; do
  echo 'Waiting for MariaDB to be ready...'
  sleep 2
done

mysql -uroot -e \"CREATE DATABASE panel;\"
mysql -uroot -e \"CREATE USER 'pterouser'@'localhost' IDENTIFIED BY '${DB_PASS}';\"
mysql -uroot -e \"GRANT ALL PRIVILEGES ON panel.* TO 'pterouser'@'localhost';\"
mysql -uroot -e \"FLUSH PRIVILEGES;\"

mysqladmin -uroot shutdown
sleep 3

# ─────── Panel download & setup ───────
mkdir -p /var/www/pterodactyl && cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
rm panel.tar.gz

chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 storage/* bootstrap/cache

cp .env.example .env

sed -i \"s|^APP_URL=.*|APP_URL=${APP_URL}|g\" .env
sed -i \"s|^APP_ENV=.*|APP_ENV=production|g\" .env
sed -i \"s|^APP_DEBUG=.*|APP_DEBUG=false|g\" .env
sed -i \"s|^DB_HOST=.*|DB_HOST=127.0.0.1|g\" .env
sed -i \"s|^DB_DATABASE=.*|DB_DATABASE=panel|g\" .env
sed -i \"s|^DB_USERNAME=.*|DB_USERNAME=pterouser|g\" .env
sed -i \"s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g\" .env
sed -i \"s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|g\" .env
sed -i \"s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|g\" .env
sed -i \"s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g\" .env
sed -i \"s|^REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g\" .env

COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

php artisan key:generate --force
php artisan migrate --seed --force
php artisan storage:link

# Create admin user non-interactively
(echo '\( {ADMIN_PASS}'; echo ' \){ADMIN_PASS}') | php artisan p:user:make --email '\( {ADMIN_EMAIL}' --username ' \){ADMIN_USER}'

# ─────── Nginx config ───────
cat > /etc/nginx/sites-available/default <<'NGINX_EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location \~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location \~ /\.ht {
        deny all;
    }
}
NGINX_EOF

# Start services
service php8.3-fpm start
service redis-server start
service nginx start

# Background tasks (queue + cron simulation)
php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3 --daemon &
(while true; do php /var/www/pterodactyl/artisan schedule:run --verbose --no-interaction; sleep 60; done) &
"

echo -e "\n\( {GREEN}KS Warrior installation complete! \){NC}"
echo -e "Panel URL:          \( {YELLOW} \){APP_URL}${NC}"
echo -e "Admin Email:        \( {YELLOW} \){ADMIN_EMAIL}${NC}"
echo -e "Admin Username:     \( {YELLOW} \){ADMIN_USER}${NC}"
echo -e "Admin Password:     \( {YELLOW} \){ADMIN_PASS}${NC}   (change immediately!)"
echo ""
echo "Container name: ks-ptero-all-in-one"
echo ""
echo "Useful commands:"
echo "  docker exec -it ks-ptero-all-in-one bash     → access shell"
echo "  docker logs ks-ptero-all-in-one              → view logs"
echo "  docker restart ks-ptero-all-in-one           → restart"
echo "  docker stop ks-ptero-all-in-one              → stop"
echo ""
echo "Enjoy your powerful Pterodactyl setup by KS Warrior! 🚀"

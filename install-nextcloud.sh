#!/bin/bash

# ==============================================================================
# Nextcloud Automated Installation Script for Ubuntu 22.04 LTS
# ==============================================================================
# This script is designed for non-interactive execution (cloud-init, Bicep, etc.)
# ==============================================================================

set -e
set -o pipefail

# --- CONFIGURATION VARIABLES ---
NEXTCLOUD_VERSION="28.0.2"
NEXTCLOUD_DOMAIN="nextcloud.local"
DB_NAME="nextcloud_db"
DB_USER="nextcloud_user"
DB_PASSWORD="Password123!"
ADMIN_USER="admin"
ADMIN_PASSWORD="AdminPassword123!"
DATA_DIRECTORY="/var/nextcloud_data"
LOG_FILE="/var/log/nextcloud-install.log"

# --- LOGGING SETUP ---
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# --- FUNCTIONS ---

prepare_system() {
    log "Updating and upgrading system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y

    log "Setting timezone to UTC..."
    timedatectl set-timezone UTC

    log "Installing base tools..."
    apt-get install -y curl wget unzip ca-certificates gnupg lsb-release vim
}

install_mariadb() {
    log "Installing MariaDB..."
    apt-get install -y mariadb-server

    log "Securing MariaDB and creating database..."
    # Idempotent database and user creation
    mysql <<-EOS
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
        GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
EOS
    
    log "Validating database connectivity..."
    mysql -u"${DB_USER}" -p"${DB_PASSWORD}" -e "STATUS;" > /dev/null
}

install_php() {
    log "Installing PHP 8.1 and extensions..."
    # Ubuntu 22.04 defaults to PHP 8.1
    apt-get install -y php-cli php-fpm php-mysql php-xml php-gd php-curl php-zip \
        php-mbstring php-intl php-bcmath php-imagick php-apcu libapache2-mod-php

    log "Configuring PHP settings..."
    PHP_INI=$(php -i | grep /etc/php/.*/cli/php.ini | cut -d" " -f5 | sed 's/cli/apache2/')
    
    sed -i "s/memory_limit = .*/memory_limit = 512M/" "$PHP_INI"
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 512M/" "$PHP_INI"
    sed -i "s/post_max_size = .*/post_max_size = 512M/" "$PHP_INI"
    sed -i "s/max_execution_time = .*/max_execution_time = 300/" "$PHP_INI"
    
    # OPcache configuration
    sed -i "s/;opcache.enable=1/opcache.enable=1/" "$PHP_INI"
    sed -i "s/;opcache.enable_cli=0/opcache.enable_cli=1/" "$PHP_INI"
    sed -i "s/;opcache.interned_strings_buffer=8/opcache.interned_strings_buffer=16/" "$PHP_INI"
    sed -i "s/;opcache.max_accelerated_files=10000/opcache.max_accelerated_files=10000/" "$PHP_INI"
    sed -i "s/;opcache.memory_consumption=128/opcache.memory_consumption=128/" "$PHP_INI"
    sed -i "s/;opcache.save_comments=1/opcache.save_comments=1/" "$PHP_INI"
    sed -i "s/;opcache.revalidate_freq=2/opcache.revalidate_freq=1/" "$PHP_INI"
}

install_apache() {
    log "Installing Apache2 and enabling modules..."
    apt-get install -y apache2
    a2enmod rewrite headers env dir mime ssl

    log "Creating VirtualHost..."
    cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName ${NEXTCLOUD_DOMAIN}
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted

        <IfModule mod_dav.c>
            Dav off
        </IfModule>

        SetEnv HOME /var/www/nextcloud
        SetEnv HTTP_HOME /var/www/nextcloud
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

    a2dissite 000-default
    a2ensite nextcloud
    systemctl restart apache2
}

install_nextcloud() {
    log "Downloading Nextcloud ${NEXTCLOUD_VERSION}..."
    if [ ! -f /tmp/nextcloud.zip ]; then
        wget "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip" -P /tmp
    fi

    log "Extracting Nextcloud..."
    if [ ! -d /var/www/nextcloud ]; then
        unzip -q /tmp/nextcloud.zip -d /var/www/
    fi

    log "Setting up data directory..."
    mkdir -p "$DATA_DIRECTORY"
    chown -R www-data:www-data "$DATA_DIRECTORY"
    chown -R www-data:www-data /var/www/nextcloud

    log "Running Nextcloud installation via occ..."
    # Run only if not already installed
    if ! [ -f /var/www/nextcloud/config/config.php ]; then
        sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
            --database "mysql" \
            --database-name "$DB_NAME" \
            --database-user "$DB_USER" \
            --database-pass "$DB_PASSWORD" \
            --data-dir "$DATA_DIRECTORY" \
            --admin-user "$ADMIN_USER" \
            --admin-pass "$ADMIN_PASSWORD"
    fi

    log "Configuring trusted domains..."
    sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 1 --value="$NEXTCLOUD_DOMAIN"
    
    log "Disabling maintenance mode..."
    sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
}

post_install_config() {
    log "Running post-install optimizations..."
    sudo -u www-data php /var/www/nextcloud/occ db:add-missing-indices
    sudo -u www-data php /var/www/nextcloud/occ db:add-missing-columns
    sudo -u www-data php /var/www/nextcloud/occ db:convert-filecache-bigint --no-interaction

    log "Configuring region and locale..."
    sudo -u www-data php /var/www/nextcloud/occ config:system:set default_phone_region --value="US"
    
    log "Setting log level..."
    sudo -u www-data php /var/www/nextcloud/occ config:system:set loglevel --value=2

    log "Enabling recommended apps..."
    sudo -u www-data php /var/www/nextcloud/occ app:enable calendar || true
    sudo -u www-data php /var/www/nextcloud/occ app:enable contacts || true

    log "Setting up Cron background jobs..."
    sudo -u www-data php /var/www/nextcloud/occ background:cron
    (crontab -u www-data -l 2>/dev/null; echo "*/5  *  *  *  * php -f /var/www/nextcloud/cron.php") | crontab -u www-data -
}

security_and_performance() {
    log "Configuring APCu..."
    sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.local --value="\OC\Memcache\APCu"

    log "Configuring file locking..."
    # Usually requires Redis for production, but using internal/database for this basic script

    log "Adding security headers in Apache configuration..."
    sed -i '/<\/Directory>/i \    Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"' /etc/apache2/sites-available/nextcloud.conf
    
    log "Preparing system for HTTPS (overwrite protocol if behind reverse proxy)..."
    sudo -u www-data php /var/www/nextcloud/occ config:system:set overwrite.cli.url --value="http://$NEXTCLOUD_DOMAIN"
    
    systemctl reload apache2
}

validate() {
    log "--- FINAL VALIDATION ---"
    
    log "Apache status:"
    systemctl is-active apache2

    log "Database status:"
    systemctl is-active mariadb

    log "Nextcloud status:"
    sudo -u www-data php /var/www/nextcloud/occ status

    echo ""
    echo "=============================================================================="
    echo " Nextcloud Installation Completed Successfully!"
    echo "=============================================================================="
    echo " Access URL: http://$NEXTCLOUD_DOMAIN"
    echo " Admin User: $ADMIN_USER"
    echo " Admin Password: $ADMIN_PASSWORD"
    echo " Log file: $LOG_FILE"
    echo "=============================================================================="
}

# --- MAIN EXECUTION ---

prepare_system
install_mariadb
install_php
install_apache
install_nextcloud
post_install_config
security_and_performance
validate

#!/bin/bash

# ==============================================================================
# SCRIPT DE INSTALACIÓN AUTOMÁTICA DE NEXTCLOUD
# ==============================================================================
# Objetivo: Instalación desatendida de Nextcloud en Ubuntu Server LTS
# Arquitectura: Apache, MariaDB, PHP (LAMP Stack)
# Autor: Antigravity AI
# ==============================================================================

# Bash estricto
set -e
set -u
set -o pipefail

# ------------------------------------------------------------------------------
# 1. VALIDACIONES INICIALES
# ------------------------------------------------------------------------------

# Verificar que el script se ejecute como root
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] Este script debe ejecutarse como root (usar sudo)."
   exit 1
fi

# Verificar versión de Ubuntu (Ubuntu 22.04 o 24.04 recomendadas)
UBUNTU_VER=$(lsb_release -rs)
if [[ "$UBUNTU_VER" != "22.04" && "$UBUNTU_VER" != "24.04" ]]; then
    echo "[WARNING] Este script ha sido probado en Ubuntu 22.04/24.04. Tu versión es $UBUNTU_VER."
    echo "[INFO] Continuando bajo Propio Riesgo..."
fi

# Verificar conectividad a internet
if ! ping -c 1 8.8.8.8 &>/dev/null; then
    echo "[ERROR] No hay conexión a internet detectada."
    exit 1
fi

echo "[PASO 1] Validaciones iniciales completadas con éxito."

# ------------------------------------------------------------------------------
# 2. DEFINICIÓN DE VARIABLES GLOBALES
# ------------------------------------------------------------------------------

# Configuración del Servidor
NC_DOMAIN=$(hostname -I | awk '{print $1}') # IP por defecto, cambiar si hay dominio
NC_ADMIN_USER="admin"
NC_ADMIN_PASS="admin" # Password inicial solicitada

# Configuración de Base de Datos
DB_NAME="nextcloud_db"
DB_USER="nextcloud_user"
DB_PASS=$(openssl rand -base64 16)
DB_ROOT_PASS=$(openssl rand -base64 16)

# Paths de Instalación
NC_WEB_ROOT="/var/www/nextcloud"
NC_DATA_DIR="/var/nextcloud_data"

echo "[PASO 2] Variables definidas. Se usará la IP: $NC_DOMAIN"

# ------------------------------------------------------------------------------
# 3. ACTUALIZACIÓN DEL SISTEMA
# ------------------------------------------------------------------------------
echo "[PASO 3] Actualizando repositorios y paquetes del sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# ------------------------------------------------------------------------------
# 4. INSTALACIÓN DE DEPENDENCIAS BASE
# ------------------------------------------------------------------------------
echo "[PASO 4] Instalando herramientas base..."
apt-get install -y curl unzip wget ca-certificates lsb-release gnupg2 apt-transport-https

# ------------------------------------------------------------------------------
# 5. INSTALACIÓN Y CONFIGURACIÓN DEL SERVIDOR WEB (APACHE)
# ------------------------------------------------------------------------------
echo "[PASO 5] Instalando y configurando Apache..."
apt-get install -y apache2

# Habilitar módulos necesarios
a2enmod rewrite dir mime env headers ssl proxy proxy_http proxy_fcgi setenvif
systemctl restart apache2

# Crear VirtualHost
cat <<EOF > /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot $NC_WEB_ROOT
    ServerName $NC_DOMAIN

    <Directory $NC_WEB_ROOT/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted

        <IfModule mod_dav.c>
            Dav off
        </IfModule>

        SetEnv HOME $NC_WEB_ROOT
        SetEnv HTTP_HOME $NC_WEB_ROOT
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2dissite 000-default.conf
systemctl reload apache2

# ------------------------------------------------------------------------------
# 6. INSTALACIÓN Y CONFIGURACIÓN DE PHP
# ------------------------------------------------------------------------------
echo "[PASO 6] Instalando PHP y extensiones necesarias..."
# Nextcloud 28+ recomienda PHP 8.2 o 8.3
apt-get install -y php php-common php-mysql php-gd php-curl php-xml php-zip php-mbstring php-intl php-bcmath php-gmp php-imagick php-opcache php-cli libapache2-mod-php

# Ajustes recomendados en php.ini
PHP_INI=$(php --ini | grep "Loaded Configuration File" | awk '{print $4}')
sed -i "s/memory_limit = .*/memory_limit = 512M/" $PHP_INI
sed -i "s/upload_max_filesize = .*/upload_max_filesize = 1G/" $PHP_INI
sed -i "s/post_max_size = .*/post_max_size = 1G/" $PHP_INI
sed -i "s/max_execution_time = .*/max_execution_time = 300/" $PHP_INI
sed -i "s/;date.timezone =.*/date.timezone = UTC/" $PHP_INI
sed -i "s/;opcache.enable=.*/opcache.enable=1/" $PHP_INI
sed -i "s/;opcache.memory_consumption=.*/opcache.memory_consumption=128/" $PHP_INI
sed -i "s/;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/" $PHP_INI
sed -i "s/;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/" $PHP_INI
sed -i "s/;opcache.revalidate_freq=.*/opcache.revalidate_freq=1/" $PHP_INI
sed -i "s/;opcache.save_comments=.*/opcache.save_comments=1/" $PHP_INI

systemctl restart apache2

# ------------------------------------------------------------------------------
# 7. INSTALACIÓN Y CONFIGURACIÓN DE LA BASE DE DATOS (MARIADB)
# ------------------------------------------------------------------------------
echo "[PASO 7] Instalando y configurando MariaDB..."
apt-get install -y mariadb-server

# Hardening básico de MariaDB (Equivalente simple a mysql_secure_installation)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"${DB_ROOT_PASS}" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"${DB_ROOT_PASS}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"${DB_ROOT_PASS}" -e "FLUSH PRIVILEGES;"

# Crear DB y Usuario para Nextcloud
mysql -u root -p"${DB_ROOT_PASS}" -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
mysql -u root -p"${DB_ROOT_PASS}" -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -u root -p"${DB_ROOT_PASS}" -e "FLUSH PRIVILEGES;"

# ------------------------------------------------------------------------------
# 8. DESCARGA E INSTALACIÓN DE NEXTCLOUD
# ------------------------------------------------------------------------------
echo "[PASO 8] Descargando y preparando Nextcloud..."
LATEST_VERSION=$(curl -s https://download.nextcloud.com/server/releases/ | grep -o 'nextcloud-[0-9.]*\.zip' | sort -V | tail -1)
wget "https://download.nextcloud.com/server/releases/${LATEST_VERSION}" -O nextcloud.zip

unzip -q nextcloud.zip -d /var/www/
rm nextcloud.zip

# Crear directorio de datos
mkdir -p $NC_DATA_DIR

# Asignar permisos y ownership
chown -R www-data:www-data $NC_WEB_ROOT
chown -R www-data:www-data $NC_DATA_DIR
chmod -R 755 $NC_WEB_ROOT
chmod -R 750 $NC_DATA_DIR

# ------------------------------------------------------------------------------
# 9. INSTALACIÓN AUTOMÁTICA DE NEXTCLOUD (CLI)
# ------------------------------------------------------------------------------
echo "[PASO 9] Ejecutando instalación via OCC..."
sudo -u www-data php $NC_WEB_ROOT/occ maintenance:install \
    --database "mysql" \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$DB_PASS" \
    --admin-user "$NC_ADMIN_USER" \
    --admin-pass "$NC_ADMIN_PASS" \
    --data-dir "$NC_DATA_DIR"

# ------------------------------------------------------------------------------
# 10. CONFIGURACIÓN POST-INSTALACIÓN
# ------------------------------------------------------------------------------
echo "[PASO 10] Ajustes de configuración de Nextcloud..."

# Trusted Domains
sudo -u www-data php $NC_WEB_ROOT/occ config:system:set trusted_domains 1 --value="$NC_DOMAIN"

# Configurar Cron Job
echo "*/5  *  *  *  * php -f $NC_WEB_ROOT/cron.php" | crontab -u www-data -

# Seguridad e índices
sudo -u www-data php $NC_WEB_ROOT/occ db:add-missing-indices --no-interaction
sudo -u www-data php $NC_WEB_ROOT/occ db:convert-filecache-bigint --no-interaction

# ------------------------------------------------------------------------------
# 11. CONFIGURACIÓN DE SSL (LETS ENCRYPT) - OPCIONAL
# ------------------------------------------------------------------------------
# Nota: Esto solo funcionará si NC_DOMAIN es un FQDN real que apunta a este server
if [[ "$NC_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "[PASO 11] Detectado FQDN. Intentando configurar Let's Encrypt..."
    apt-get install -y certbot python3-certbot-apache
    # certbot --apache -d "$NC_DOMAIN" --non-interactive --agree-tos --email webmaster@$NC_DOMAIN || echo "[SKIP] Certbot falló, continuando con HTTP."
else
    echo "[PASO 11] No se detectó dominio público (solo IP). Saltando SSL."
fi

# ------------------------------------------------------------------------------
# 12. VERIFICACIONES FINALES
# ------------------------------------------------------------------------------
echo "[PASO 12] Verificando servicios..."
systemctl is-active --quiet apache2 && echo "Apache: [OK]" || echo "Apache: [FALLO]"
systemctl is-active --quiet mariadb && echo "MariaDB: [OK]" || echo "MariaDB: [FALLO]"

echo "--------------------------------------------------------------------------"
echo " ¡INSTALACIÓN COMPLETADA EXITOSAMENTE! "
echo "--------------------------------------------------------------------------"
echo " URL: http://$NC_DOMAIN"
echo " Usuario Admin: $NC_ADMIN_USER"
echo " Password Admin: $NC_ADMIN_PASS (¡CÁMBIALA AL INICIAR SESIÓN!)"
echo "--------------------------------------------------------------------------"
echo " Guarda estas credenciales en un lugar seguro."
echo " Base de Datos (root pass): $DB_ROOT_PASS"
echo "--------------------------------------------------------------------------"

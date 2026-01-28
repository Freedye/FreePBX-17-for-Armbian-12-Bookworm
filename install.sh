#!/bin/bash

# ============================================================================
# * Copyright 2026 by Slythel
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3.0
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
#
# This FreePBX install script and all concepts are property of
# Slythel.
# This install script is free to use for installing FreePBX
# along with dependent packages only but carries no guarantee on performance
# and is used at your own risk.  This script carries NO WARRANTY.
# PROJECT:   Armbian PBX Installer (Asterisk 22 + FreePBX 17 + LAMP) v0.4.4
# TARGET:    Debian 12 Bookworm ARM64
# ============================================================================

# --- 1. CONFIGURATION ---
REPO_OWNER="slythel2"
REPO_NAME="FreePBX-17-for-Armbian-12-Bookworm"
FALLBACK_ARTIFACT="https://github.com/slythel2/FreePBX-17-for-Armbian-12-Bookworm/releases/download/1.0/asterisk-22-current-arm64-debian12-v2.tar.gz"

DB_ROOT_PASS="armbianpbx"
LOG_FILE="/var/log/pbx_install.log"
DEBIAN_FRONTEND=noninteractive

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"; }

warn() { echo -e "${YELLOW}[WARNING] $1${NC}" | tee -a "$LOG_FILE"; }

error() { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

backup_asterisk () {
    BACKUP_DIR="/tmp/asterisk_backup_$(date +%s)"
    mkdir -p "$BACKUP_DIR"
    
    log "Creating backup of current Asterisk installation..."
    if [ -f /usr/sbin/asterisk ]; then
        cp /usr/sbin/asterisk "$BACKUP_DIR/" || error "Failed to backup binary"
    fi
    if [ -d /usr/lib/asterisk/modules ]; then
        mkdir -p "$BACKUP_DIR/modules"
        cp -r /usr/lib/asterisk/modules/* "$BACKUP_DIR/modules/" 2>/dev/null || true
    fi
}

stop_asterisk() {
    systemctl stop asterisk
    sleep 2
    pkill -9 asterisk 2>/dev/null || true
    sleep 1
}

download_asterisk() {
        LATEST_URL=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" | jq -r '.assets[] | select(.name | contains("asterisk")) | .browser_download_url' | head -n 1)
    
    if [ -z "$LATEST_URL" ]; then
        warn "Could not fetch latest release, using fallback URL."
        ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
    else
        log "Latest release found: $LATEST_URL"
        ASTERISK_ARTIFACT_URL="$LATEST_URL"
    fi
    
    STAGE_DIR="/tmp/asterisk_update_stage"
    rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
    
    # Download with retry and validation
    DOWNLOAD_SUCCESS=0
    for attempt in {1..3}; do
        if wget --show-progress -O /tmp/asterisk_update.tar.gz "$ASTERISK_ARTIFACT_URL"; then
            if tar -tzf /tmp/asterisk_update.tar.gz > /dev/null 2>&1; then
                DOWNLOAD_SUCCESS=1
                log "Update artifact downloaded and verified."
                break
            else
                warn "Downloaded file corrupted. Attempt $attempt/3"
                rm -f /tmp/asterisk_update.tar.gz
            fi
        else
            warn "Download failed. Attempt $attempt/3"
            rm -f /tmp/asterisk_update.tar.gz
        fi
        sleep 2
    done
    
    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        error "Failed to download update after 3 attempts. Restoring backup..."
        # Rollback not needed here since we haven't changed anything yet
        rm -rf "$BACKUP_DIR"
        exit 1
    fi

    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        error "Failed to download update after 3 attempts. Restoring backup..."
        # Rollback not needed here since we haven't changed anything yet
        rm -rf "$BACKUP_DIR"
        exit 1
    fi
}

download_necessary_files() {
    FOLDER_URL="https://api.github.com/repos/Freedye/FreePBX-17-for-Armbian-12-Bookworm/contents/files"
    FILES=$(curl -s $FOLDER_URL | jq -r '.[].download_url')

    for FILE in $FILES; do
        log "Scaricando $(basename $FILE)..."
        wget -q $FILE -P /tmp/files/
    done
}

extract_update() {
    tar -xzf /tmp/asterisk_update.tar.gz -C "$STAGE_DIR"

    log "Deploying updated binaries and modules..."
    [ -d "$STAGE_DIR/usr/sbin" ] && cp -f "$STAGE_DIR/usr/sbin/asterisk" /usr/sbin/
    [ -d "$STAGE_DIR/usr/lib/asterisk/modules" ] && cp -rf "$STAGE_DIR/usr/lib/asterisk/modules"/* /usr/lib/asterisk/modules/
    
    # 6. PERMISSION RESTORATION
    log "Restoring correct permissions..."
    chown asterisk:asterisk /usr/sbin/asterisk
    chmod +x /usr/sbin/asterisk
    chown -R asterisk:asterisk /usr/lib/asterisk/modules
    chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
    
    # 7. POST-UPDATE HEALTH CHECK
    rm -rf "$STAGE_DIR" /tmp/asterisk_update.tar.gz
    ldconfig
}

check_pulse() {
    ASTERISK_HEALTHY=0
    for i in {1..10}; do
        if asterisk -rx "core show version" &>/dev/null; then
            ASTERISK_HEALTHY=1
            log "✓ Asterisk is responding to CLI - Update successful!"
            break
        fi
        warn "Waiting for Asterisk to respond... ($i/10)"
        sleep 2
    done
    
    if [ $ASTERISK_HEALTHY -eq 0 ]; then
        # ROLLBACK!
        error "Asterisk failed to start after update. Rolling back to previous version..."
        systemctl stop asterisk
        pkill -9 asterisk 2>/dev/null || true
        
        # Restore from backup
        if [ -f "$BACKUP_DIR/asterisk" ]; then
            cp -f "$BACKUP_DIR/asterisk" /usr/sbin/asterisk
            chown asterisk:asterisk /usr/sbin/asterisk
            chmod +x /usr/sbin/asterisk
        fi
        if [ -d "$BACKUP_DIR/modules" ]; then
            rm -rf /usr/lib/asterisk/modules/*
            cp -r "$BACKUP_DIR/modules"/* /usr/lib/asterisk/modules/
            chown -R asterisk:asterisk /usr/lib/asterisk/modules
        fi
        
        ldconfig
        systemctl start asterisk
        sleep 3
        
        rm -rf "$BACKUP_DIR"
        error "Rollback complete. Previous Asterisk version restored. Please check logs: journalctl -xeu asterisk"
    fi
}

optimize_php() {
    for INI in /etc/php/8.2/apache2/php.ini /etc/php/8.2/cli/php.ini; do
        if [ -f "$INI" ]; then
            sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$INI"
            sed -i 's/^;opcache.memory_consumption=.*/opcache.memory_consumption=128/' "$INI"
            sed -i 's/^;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=8/' "$INI"
            sed -i 's/^;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$INI"

            sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$INI"
            sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 120M/' "$INI"
            sed -i 's/^post_max_size = .*/post_max_size = 120M/' "$INI"
            sed -i 's/^;date.timezone =.*/date.timezone = UTC/' "$INI"
            
            # Configure MySQL socket paths for PDO/MySQLi
            sed -i "s|^;*pdo_mysql.default_socket.*|pdo_mysql.default_socket = /run/mysqld/mysqld.sock|" "$INI"
            sed -i "s|^;*mysqli.default_socket.*|mysqli.default_socket = /run/mysqld/mysqld.sock|" "$INI"
            sed -i "s|^;*mysql.default_socket.*|mysql.default_socket = /run/mysqld/mysqld.sock|" "$INI"
        fi
    done
}

install_ioncube() {
    log "Installing ionCube Loader for PHP..."
    IONCUBE_DIR="/tmp/ioncube_install"
    rm -rf "$IONCUBE_DIR" && mkdir -p "$IONCUBE_DIR"
    cd "$IONCUBE_DIR"

    # Download ionCube Loader for ARM64
    if wget -q https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_aarch64.tar.gz; then
        tar xzf ioncube_loaders_lin_aarch64.tar.gz
        
        # Determine PHP extension directory
        PHP_EXT_DIR=$(php -i 2>/dev/null | grep "^extension_dir" | awk '{print $3}')
        if [ -z "$PHP_EXT_DIR" ]; then
            # Fallback to common path for PHP 8.2
            PHP_EXT_DIR="/usr/lib/php/20220829"
        fi
        
        # Copy the loader for PHP 8.2
        if [ -f "ioncube/ioncube_loader_lin_8.2.so" ]; then
            cp ioncube/ioncube_loader_lin_8.2.so "$PHP_EXT_DIR/"
            
            # Configure PHP to load ionCube (must be loaded FIRST, before other extensions, or PHP will break)
            echo "zend_extension = $PHP_EXT_DIR/ioncube_loader_lin_8.2.so" > /etc/php/8.2/mods-available/ioncube.ini
            ln -sf /etc/php/8.2/mods-available/ioncube.ini /etc/php/8.2/apache2/conf.d/00-ioncube.ini
            ln -sf /etc/php/8.2/mods-available/ioncube.ini /etc/php/8.2/cli/conf.d/00-ioncube.ini
            
            log "✓ ionCube Loader installed successfully"
        else
            warn "ionCube Loader file not found, FreePBX commercial modules may not work"
        fi
    else
        warn "Failed to download ionCube Loader, FreePBX commercial modules may not work"
    fi

    cd /
    rm -rf "$IONCUBE_DIR"
}

configure_mariadb() {
    mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true

    mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS asterisk; CREATE DATABASE IF NOT EXISTS asteriskcdrdb;"
    # Grant for both socket (@localhost) and TCP (@127.0.0.1) connections
    mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';"
    mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'127.0.0.1' IDENTIFIED BY '$DB_ROOT_PASS';"
    mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';"
    mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'127.0.0.1';"
    mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"
}

if [[ $EUID -ne 0 ]]; then echo "Run as root!"; exit 1; fi

# --- UPDATER ---
if [[ "$1" == "--update" ]]; then
    log "Starting Asterisk 22 Robust Update with Rollback Protection..."
    backup_asterisk
    log "Backup created at: $BACKUP_DIR"
    
    # 2. ENVIRONMENT VERIFICATION
    log "Verifying Asterisk environment..."
    
    # Ensure all critical directories exist
    mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
    
    # Verify asterisk.conf exists
    if [ ! -f /etc/asterisk/asterisk.conf ]; then
        warn "asterisk.conf missing, recreating..."
        cp /tmp/files/asterisk.conf /etc/asterisk/asterisk.conf
    fi
    
    # 3. STOP ASTERISK SAFELY
    log "Stopping Asterisk..."
    stop_asterisk
    
    # 4. DOWNLOAD UPDATE
    if ! command -v jq &> /dev/null; then apt-get update && apt-get install -y jq zram-config; fi
    
    log "Fetching latest Asterisk 22 release from GitHub..."
    download_asterisk
    download_necessary_files
    
    # 5. DEPLOY UPDATE
    log "Extracting update..."
    extract_update
    
    log "Starting Asterisk and performing health check..."
    systemctl start asterisk
    sleep 5

    # Verify Asterisk is responsive
    check_pulse
    
    # 8. FINAL VALIDATION AND CLEANUP
    log "Running FreePBX reload..."
    if command -v fwconsole &> /dev/null; then
        fwconsole reload || warn "FreePBX reload had warnings (this is often normal)"
    fi
    
    rm -rf "$BACKUP_DIR"
    
    ASTERISK_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -n1 | awk '{print $2}' || echo "Unknown")
    echo -e "${GREEN}========================================================${NC}"
    echo -e "${GREEN}     ASTERISK UPDATE COMPLETED SUCCESSFULLY!           ${NC}"
    echo -e "${GREEN}            Version: $ASTERISK_VERSION                        ${NC}"
    echo -e "${GREEN}========================================================${NC}"
    exit 0
fi

# --- 2. MAIN INSTALLER ---
clear
echo "========================================================"
echo "   ARMBIAN 12 FREEPBX 17 INSTALLER (Asterisk 22 LTS)    "
echo "========================================================"

log "System upgrade and core dependencies..."
apt-get update && apt-get upgrade -y
apt-get install -y --no-install-recommends \
    zram-config git curl wget vim htop subversion sox pkg-config \
    sngrep apache2 mariadb-server mariadb-client odbc-mariadb \
    libxml2 libsqlite3-0 libjansson4 libedit2 libxslt1.1 \
    libopus0 libvorbis0a libspeex1 libspeexdsp1 libgsm1 \
    unixodbc unixodbc-dev odbcinst libltdl7 libicu-dev \
    liburiparser1 libjwt-dev liblua5.4-0 libtinfo6 \
    libsrtp2-1 libportaudio2 nodejs npm acl haveged jq \
    dnsutils bind9-dnsutils bind9-host fail2ban \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php

# PHP Optimization + MySQL Socket Configuration
optimize_php

# Install ionCube Loader (required for FreePBX commercial modules, some are working soo..I'm installing those too.)
install_ioncube

# Preventive fix for NetworkManager D-Bus connection, may not be needed in the future,
# but it doesn't hurt to have it for now.
log "Configuring NetworkManager systemd override..."
mkdir -p /etc/systemd/system/NetworkManager.service.d
cp /tmp/files/dbus-fix.conf /etc/systemd/system/NetworkManager.service.d/dbus-fix.conf
systemctl daemon-reload

# --- 3. ASTERISK USER & ARTIFACT ---
log "Configuring Asterisk user..."
getent group asterisk >/dev/null || groupadd asterisk
if ! getent passwd asterisk >/dev/null; then
    useradd -r -d /var/lib/asterisk -s /bin/bash -g asterisk asterisk
    usermod -aG audio,dialout,www-data asterisk
fi

log "Fetching latest Asterisk 22 release..."
# Try to get the latest release from GitHub API (slythel2 repo)
download_asterisk

tar -xzf /tmp/asterisk.tar.gz -C /
rm /tmp/asterisk.tar.gz

# Ensure all directories exist
mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
ldconfig

# Create a clean asterisk.conf
cp /tmp/files/asterisk.conf /etc/asterisk/asterisk.conf
chown asterisk:asterisk /etc/asterisk/asterisk.conf

# Systemd Service Fix
cp /tmp/files/asterisk.service /etc/systemd/system/asterisk.service

systemctl daemon-reload
systemctl enable asterisk mariadb apache2

# --- 4. DATABASE SETUP ---
log "Initializing MariaDB..."

# Create MariaDB runtime directory before starting service
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
chmod 755 /run/mysqld

# Create tmpfiles.d configuration to persist /run/mysqld across reboots
log "Configuring MariaDB tmpfiles.d for reboot persistence..."
mkdir -p /etc/tmpfiles.d
cp /tmp/files/mariadb.conf /etc/tmpfiles.d/mariadb.conf

# Apply tmpfiles configuration immediately
systemd-tmpfiles --create /etc/tmpfiles.d/mariadb.conf 2>/dev/null || true

# Configure MariaDB to listen on TCP (FreePBX needs this)
cp /tmp/files/99-freepbx.cnf /etc/mysql/mariadb.conf.d/99-freepbx.cnf

systemctl start mariadb

# Wait for MariaDB to fully start
sleep 3
if ! systemctl is-active --quiet mariadb; then
    error "MariaDB failed to start. Check: journalctl -xeu mariadb.service"
fi

configure_mariadb

# Configure MySQL socket for FreePBX which must be done before FreePBX install
log "Configuring MySQL socket for FreePBX..."
REAL_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)
if [ -z "$REAL_SOCKET" ]; then
    error "MariaDB socket not found! MariaDB may not be running correctly."
fi
log "Found MariaDB socket at: $REAL_SOCKET"
ln -sf "$REAL_SOCKET" /tmp/mysql.sock
chmod 777 /tmp/mysql.sock 2>/dev/null || true

# --- 5. APACHE CONFIGURATION ---
log "Hardening Apache configuration..."
# Update DocumentRoot block to allow .htaccess
cp /tmp/files/freepbx.conf /etc/apache2/sites-available/freepbx.conf

sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
a2enmod rewrite
a2ensite freepbx.conf
a2dissite 000-default.conf

# Create redirect from root to FreePBX admin
cp /tmp/files/index.pho /var/www/html/index.php
chown asterisk:asterisk /var/www/html/index.php

systemctl restart apache2

# --- 6. START ASTERISK BEFORE FREEPBX ---
log "Starting Asterisk and waiting for readiness..."
systemctl restart asterisk
sleep 5

# Validation loop
ASTERISK_READY=0
for i in {1..10}; do
    if asterisk -rx "core show version" &>/dev/null; then
        ASTERISK_READY=1
        log "Asterisk is responding to CLI."
        break
    fi
    warn "Waiting for Asterisk... ($i/10)"
    sleep 3
done

if [ $ASTERISK_READY -eq 0 ]; then
    error "Asterisk failed to respond. Check /var/log/asterisk/messages"
fi

# --- DNS VERIFICATION (Critical for SIP Trunks) ---
log "Verifying DNS resolution for SIP trunks..."
if command -v dig &>/dev/null; then
    # Test DNS resolution with a common DNS server
    TEST_DOMAIN="google.com"
    if dig "$TEST_DOMAIN" +short | grep -q .; then
        log "✓ DNS resolution is working correctly"
    else
        warn "DNS resolution may have issues. Check /etc/resolv.conf - SIP trunk registration may fail!"
    fi
else
    warn "dig command not available. DNS packages may not be installed correctly."
fi

# --- 7. FREEPBX INSTALLATION ---
log "Installing FreePBX 17..."
cd /usr/src
wget -q http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz
tar xfz freepbx-17.0-latest.tgz
cd freepbx

# Verify MySQL connection works before installing
log "Verifying MySQL connection..."
if ! mysql -u asterisk -p"$DB_ROOT_PASS" -e "SELECT 1;" &>/dev/null; then
    error "Cannot connect to MySQL as asterisk user. Check credentials."
fi

# Install FreePBX
./install -n \
    --dbuser asterisk \
    --dbpass "$DB_ROOT_PASS" \
    --webroot /var/www/html \
    --user asterisk \
    --group asterisk

# --- 8. FINAL FIXES ---
log "Finalizing permissions and CDR setup..."

# ODBC Fix which needs variables expansion
ODBC_DRIVER=$(find /usr/lib -name "libmaodbc.so" | head -n 1)
if [ -n "$ODBC_DRIVER" ]; then
    cp /tmp/files/odbcinst.ini /etc/odbcinst.ini
    cp /tmp/files/odbc.ini /etc/odbc.ini
fi

if command -v fwconsole &> /dev/null; then
    fwconsole chown
    
    log "Restarting Asterisk to load DNS libraries..."
    systemctl restart asterisk
    sleep 5
    
    # Install complete FreePBX module set, most people will use every module anyways,
    # or install them later, so why not.
    log "Installing FreePBX modules (this may take 10-15 minutes)..."
    MODULES_LIST="asterisk-cli backup blacklist bulkhandler certman cidlookup configedit contactmanager customappsreg featurecodeadmin presencestate qxact_reports recordings soundlang superfecta ucp userman amd announcement calendar callback callflow callforward callrecording callwaiting conferences dictate directory disa donotdisturb findmefollow infoservices ivr languages miscapps miscdests paging parking queueprio queues ringgroups setcid timeconditions tts vmblast wakeup dahdiconfig api sms webrtc dashboard asterisklogfiles cdr cel phpinfo printextensions weakpasswords asteriskapi arimanager fax filestore iaxsettings musiconhold pinsets sipsettings ttsengines voicemail pm2"
    fwconsole ma downloadinstall $MODULES_LIST --quiet

    # Remove firewall module (causes network issues on Armbian - also proprietary module)
    fwconsole ma remove firewall &>/dev/null || true
    
    log "All modules installed. Reloading FreePBX..."
    fwconsole reload
fi

# Persistence Service
cp /tmp/files/fix_free_perm.sh /usr/local/bin/fix_free_perm.sh
chmod +x /usr/local/bin/fix_free_perm.sh

cp /tmp/files/free_perm_fix.service /etc/systemd/system/free-perm-fix.service
systemctl enable free-perm-fix.service

# --- FAIL2BAN SECURITY ---
log "Configuring Fail2ban for Asterisk protection..."

# Create Asterisk PJSIP authentication failure filter
cp /tmp/files/asterisk-pjsip.conf /etc/fail2ban/filter.d/asterisk-pjsip.conf

# Create Asterisk jail configuration with GENEROUS limits.. FreePBX is strange about SIP Registrations,
# so we need to be lenient. (This especially applies if you use Wildix IP Phones)
cp /tmp/files/asterisk.local /etc/fail2ban/jail.d/asterisk.local

# Enable and start fail2ban
systemctl enable fail2ban
systemctl restart fail2ban

# Wait for fail2ban to initialize
sleep 2

# Verify fail2ban is monitoring Asterisk
if systemctl is-active --quiet fail2ban; then
    JAILS_ACTIVE=$(fail2ban-client status 2>/dev/null | grep "Jail list" | grep -o "asterisk" | wc -l)
    if [ "$JAILS_ACTIVE" -ge 1 ]; then
        log "✓ Fail2ban is active and protecting Asterisk (${JAILS_ACTIVE} jails)"
    else
        warn "Fail2ban is running but jails may not be active yet. Check: fail2ban-client status"
    fi
else
    warn "Fail2ban failed to start. Check: systemctl status fail2ban"
fi

# SSH Login Status Banner
log "Creating system status banner..."
cp /tmp/files/99-pbx-status /etc/update-motd.d/99-pbx-status
chmod +x /etc/update-motd.d/99-pbx-status
rm -f /etc/motd 2>/dev/null  # Remove static motd to avoid duplication
npm cache clean --force
rm -rf /root/.cache

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}            FREEPBX INSTALLATION COMPLETE!              ${NC}"
echo -e "${GREEN}           Access: http://$(hostname -I | cut -d' ' -f1)/admin  ${NC}"
echo -e "${GREEN}========================================================${NC}"

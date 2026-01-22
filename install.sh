#!/bin/bash

# ============================================================================
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

if [[ $EUID -ne 0 ]]; then echo "Run as root!"; exit 1; fi

# --- UPDATER ---
if [[ "$1" == "--update" ]]; then
    log "Starting Asterisk 22 Robust Update with Rollback Protection..."
    
    # 1. PRE-UPDATE BACKUP
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
    log "Backup created at: $BACKUP_DIR"
    
    # 2. ENVIRONMENT VERIFICATION
    log "Verifying Asterisk environment..."
    
    # Ensure all critical directories exist
    mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
    
    # Verify asterisk.conf exists
    if [ ! -f /etc/asterisk/asterisk.conf ]; then
        warn "asterisk.conf missing, recreating..."
        cat > /etc/asterisk/asterisk.conf <<'EOF'
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
[options]
runuser = asterisk
rungroup = asterisk
EOF
    fi
    
    # 3. STOP ASTERISK SAFELY
    log "Stopping Asterisk..."
    systemctl stop asterisk
    sleep 2
    pkill -9 asterisk 2>/dev/null || true
    sleep 1
    
    # Verify no asterisk processes remain
    if pgrep asterisk > /dev/null; then
        warn "Asterisk processes still running, force killing..."
        killall -9 asterisk 2>/dev/null || true
        sleep 1
    fi
    
    # 4. DOWNLOAD UPDATE
    if ! command -v jq &> /dev/null; then apt-get update && apt-get install -y jq; fi
    
    log "Fetching latest Asterisk 22 release from GitHub..."
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
    
    # 5. DEPLOY UPDATE
    log "Extracting update..."
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
    
    log "Starting Asterisk and performing health check..."
    systemctl start asterisk
    sleep 5
    
    # Verify Asterisk is responsive
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
apt-get install -y \
    git curl wget vim htop subversion sox pkg-config sngrep \
    apache2 mariadb-server mariadb-client odbc-mariadb \
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
for INI in /etc/php/8.2/apache2/php.ini /etc/php/8.2/cli/php.ini; do
    if [ -f "$INI" ]; then
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

# Install ionCube Loader (required for FreePBX commercial modules, some are working soo..I'm installing those too.)
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

# Preventive fix for NetworkManager D-Bus connection, may not be needed in the future,
# but it doesn't hurt to have it for now.
log "Configuring NetworkManager systemd override..."
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/dbus-fix.conf <<'EOF'
[Unit]
After=dbus.service
Requires=dbus.service

[Service]
Environment="DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"
Restart=on-failure
RestartSec=5
EOF
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
LATEST_URL=$(curl -s "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" | jq -r '.assets[] | select(.name | contains("asterisk")) | .browser_download_url' | head -n 1)

if [ -z "$LATEST_URL" ]; then
    warn "Could not fetch latest release from GitHub API, using fallback URL."
    ASTERISK_ARTIFACT_URL="$FALLBACK_ARTIFACT"
else
    log "Latest release found: $LATEST_URL"
    ASTERISK_ARTIFACT_URL="$LATEST_URL"
fi

log "Downloading Asterisk artifact..."
# Download with retry mechanism and error handling
DOWNLOAD_SUCCESS=0
for attempt in {1..3}; do
    if wget --show-progress -O /tmp/asterisk.tar.gz "$ASTERISK_ARTIFACT_URL"; then
        # Verify the downloaded file is valid
        if tar -tzf /tmp/asterisk.tar.gz >/dev/null 2>&1; then
            DOWNLOAD_SUCCESS=1
            log "Asterisk artifact downloaded and verified successfully."
            break
        else
            warn "Downloaded file is corrupted. Attempt $attempt/3"
            rm -f /tmp/asterisk.tar.gz
        fi
    else
        warn "Download failed. Attempt $attempt/3"
        rm -f /tmp/asterisk.tar.gz
    fi
    sleep 2
done

if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
    error "Failed to download Asterisk artifact after 3 attempts. Check your internet connection and the URL: $FALLBACK_ARTIFACT"
fi

tar -xzf /tmp/asterisk.tar.gz -C /
rm /tmp/asterisk.tar.gz

# Ensure all directories exist
mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk /usr/lib/asterisk/modules
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk /etc/asterisk
ldconfig

# Create a clean asterisk.conf
cat > /etc/asterisk/asterisk.conf <<'EOF'
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
[options]
runuser = asterisk
rungroup = asterisk
EOF
chown asterisk:asterisk /etc/asterisk/asterisk.conf

# Systemd Service Fix
cat > /etc/systemd/system/asterisk.service <<'EOF'
[Unit]
Description=Asterisk PBX
After=network.target mariadb.service
[Service]
Type=simple
User=asterisk
Group=asterisk
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

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
cat > /etc/tmpfiles.d/mariadb.conf <<'EOF'
# MariaDB runtime directory
# Type Path            Mode UID   GID   Age Argument
d      /run/mysqld    0755 mysql mysql -   -
EOF

# Apply tmpfiles configuration immediately
systemd-tmpfiles --create /etc/tmpfiles.d/mariadb.conf 2>/dev/null || true

# Configure MariaDB to listen on TCP (FreePBX needs this)
cat > /etc/mysql/mariadb.conf.d/99-freepbx.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
port = 3306
socket = /run/mysqld/mysqld.sock
EOF

systemctl start mariadb

# Wait for MariaDB to fully start
sleep 3
if ! systemctl is-active --quiet mariadb; then
    error "MariaDB failed to start. Check: journalctl -xeu mariadb.service"
fi

mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null || true

mysql -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS asterisk; CREATE DATABASE IF NOT EXISTS asteriskcdrdb;"
# Grant for both socket (@localhost) and TCP (@127.0.0.1) connections
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asterisk.* TO 'asterisk'@'127.0.0.1' IDENTIFIED BY '$DB_ROOT_PASS';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';"
mysql -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'127.0.0.1';"
mysql -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

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
cat > /etc/apache2/sites-available/freepbx.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    
    # Automatic redirect from root to /admin
    RewriteEngine On
    RewriteCond %{REQUEST_URI} ^/$
    RewriteRule ^/$ /admin [R=302,L]
    
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
a2enmod rewrite
a2ensite freepbx.conf
a2dissite 000-default.conf

# Create redirect from root to FreePBX admin
cat > /var/www/html/index.php <<'EOF'
<?php
header('Location: /admin');
exit;
?>
EOF
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
cat > /etc/odbcinst.ini <<EOF
[MariaDB]
Description=ODBC for MariaDB
Driver=$ODBC_DRIVER
Setup=$ODBC_DRIVER
UsageCount=1
EOF

cat > /etc/odbc.ini <<EOF
[MySQL-asteriskcdrdb]
Description=MySQL connection to 'asteriskcdrdb' database
Driver=MariaDB
Server=localhost
Database=asteriskcdrdb
Port=3306
Socket=$REAL_SOCKET
Option=3
EOF
fi

if command -v fwconsole &> /dev/null; then
    fwconsole chown
    
    log "Restarting Asterisk to load DNS libraries..."
    systemctl restart asterisk
    sleep 5
    
    # Install complete FreePBX module set, most people will use every module anyways,
    # or install them later, so why not.
    log "Installing FreePBX modules (this may take 10-15 minutes)..."
    
    # ===== ADMIN MODULES =====
    fwconsole ma downloadinstall asterisk-cli &>/dev/null || true
    fwconsole ma downloadinstall backup &>/dev/null || true
    fwconsole ma downloadinstall blacklist &>/dev/null || true
    fwconsole ma downloadinstall bulkhandler &>/dev/null || true
    fwconsole ma downloadinstall certman &>/dev/null || true
    fwconsole ma downloadinstall cidlookup &>/dev/null || true
    fwconsole ma downloadinstall configedit &>/dev/null || true
    fwconsole ma downloadinstall contactmanager &>/dev/null || true
    fwconsole ma downloadinstall customappsreg &>/dev/null || true
    fwconsole ma downloadinstall featurecodeadmin &>/dev/null || true
    fwconsole ma downloadinstall presencestate &>/dev/null || true
    fwconsole ma downloadinstall qxact_reports &>/dev/null || true
    fwconsole ma downloadinstall recordings &>/dev/null || true
    fwconsole ma downloadinstall soundlang &>/dev/null || true
    fwconsole ma downloadinstall superfecta &>/dev/null || true
    fwconsole ma downloadinstall ucp &>/dev/null || true
    fwconsole ma downloadinstall userman &>/dev/null || true
    
    # ===== APPLICATION MODULES =====
    fwconsole ma downloadinstall amd &>/dev/null || true
    fwconsole ma downloadinstall announcement &>/dev/null || true
    fwconsole ma downloadinstall calendar &>/dev/null || true
    fwconsole ma downloadinstall callback &>/dev/null || true
    fwconsole ma downloadinstall callflow &>/dev/null || true
    fwconsole ma downloadinstall callforward &>/dev/null || true
    fwconsole ma downloadinstall callrecording &>/dev/null || true
    fwconsole ma downloadinstall callwaiting &>/dev/null || true
    fwconsole ma downloadinstall conferences &>/dev/null || true
    fwconsole ma downloadinstall dictate &>/dev/null || true
    fwconsole ma downloadinstall directory &>/dev/null || true
    fwconsole ma downloadinstall disa &>/dev/null || true
    fwconsole ma downloadinstall donotdisturb &>/dev/null || true
    fwconsole ma downloadinstall findmefollow &>/dev/null || true
    fwconsole ma downloadinstall infoservices &>/dev/null || true
    fwconsole ma downloadinstall ivr &>/dev/null || true
    fwconsole ma downloadinstall languages &>/dev/null || true
    fwconsole ma downloadinstall miscapps &>/dev/null || true
    fwconsole ma downloadinstall miscdests &>/dev/null || true
    fwconsole ma downloadinstall paging &>/dev/null || true
    fwconsole ma downloadinstall parking &>/dev/null || true
    fwconsole ma downloadinstall queueprio &>/dev/null || true
    fwconsole ma downloadinstall queues &>/dev/null || true
    fwconsole ma downloadinstall ringgroups &>/dev/null || true
    fwconsole ma downloadinstall setcid &>/dev/null || true
    fwconsole ma downloadinstall timeconditions &>/dev/null || true
    fwconsole ma downloadinstall tts &>/dev/null || true
    fwconsole ma downloadinstall vmblast &>/dev/null || true
    fwconsole ma downloadinstall wakeup &>/dev/null || true
    
    # ===== CONNECTIVITY MODULES =====
    fwconsole ma downloadinstall dahdiconfig &>/dev/null || true
    fwconsole ma downloadinstall api &>/dev/null || true
    fwconsole ma downloadinstall sms &>/dev/null || true
    fwconsole ma downloadinstall webrtc &>/dev/null || true
    
    # ===== DASHBOARD =====
    fwconsole ma downloadinstall dashboard &>/dev/null || true
    
    # ===== REPORTS MODULES =====
    fwconsole ma downloadinstall asterisklogfiles &>/dev/null || true
    fwconsole ma downloadinstall cdr &>/dev/null || true
    fwconsole ma downloadinstall cel &>/dev/null || true
    fwconsole ma downloadinstall phpinfo &>/dev/null || true
    fwconsole ma downloadinstall printextensions &>/dev/null || true
    fwconsole ma downloadinstall weakpasswords &>/dev/null || true
    
    # ===== SETTINGS MODULES =====
    fwconsole ma downloadinstall asteriskapi &>/dev/null || true
    fwconsole ma downloadinstall arimanager &>/dev/null || true
    fwconsole ma downloadinstall fax &>/dev/null || true
    fwconsole ma downloadinstall filestore &>/dev/null || true
    fwconsole ma downloadinstall iaxsettings &>/dev/null || true
    fwconsole ma downloadinstall musiconhold &>/dev/null || true
    fwconsole ma downloadinstall pinsets &>/dev/null || true
    fwconsole ma downloadinstall sipsettings &>/dev/null || true
    fwconsole ma downloadinstall ttsengines &>/dev/null || true
    fwconsole ma downloadinstall voicemail &>/dev/null || true
    
    # ===== OTHER =====
    fwconsole ma downloadinstall pm2 &>/dev/null || true
    
    # Remove firewall module (causes network issues on Armbian - also proprietary module)
    fwconsole ma remove firewall &>/dev/null || true
    
    log "All modules installed. Reloading FreePBX..."
    fwconsole reload
fi

# Persistence Service
cat > /usr/local/bin/fix_free_perm.sh <<'EOF'
#!/bin/bash
DYN_SOCKET=$(find /run /var/run -name mysqld.sock 2>/dev/null | head -n 1)
[ -n "$DYN_SOCKET" ] && ln -sf "$DYN_SOCKET" /tmp/mysql.sock
mkdir -p /var/run/asterisk /var/log/asterisk
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /etc/asterisk
if [ -x /usr/sbin/fwconsole ]; then
    /usr/sbin/fwconsole chown &>/dev/null
fi
exit 0
EOF
chmod +x /usr/local/bin/fix_free_perm.sh

cat > /etc/systemd/system/free-perm-fix.service <<'EOF'
[Unit]
Description=FreePBX Permission Fix
After=asterisk.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix_free_perm.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable free-perm-fix.service

# --- FAIL2BAN SECURITY ---
log "Configuring Fail2ban for Asterisk protection..."

# Create Asterisk PJSIP authentication failure filter
cat > /etc/fail2ban/filter.d/asterisk-pjsip.conf <<'EOF'
# Fail2Ban filter for Asterisk PJSIP authentication failures
# Detects: Invalid passwords, failed ACLs, wrong accounts, brute force attempts
[Definition]

# PJSIP Security Events (Asterisk 13+)
failregex = ^.*SecurityEvent="(FailedACL|InvalidAccountID|ChallengeResponseFailed|InvalidPassword)".*RemoteAddress="IPV[46]/(UDP|TCP|TLS)/<HOST>/[0-9]+".*
            ^.*chan_sip\.c:.*Registration from '.*' failed for '<HOST>:[0-9]+' - Wrong password$
            ^.*chan_sip\.c:.*Registration from '.*' failed for '<HOST>:[0-9]+' - No matching peer found$
            ^.*chan_sip\.c:.*Registration from '.*' failed for '<HOST>:[0-9]+' - Username/auth name mismatch$
            ^.*chan_sip\.c:.*Host <HOST> failed to authenticate as .*$
            ^.*chan_sip\.c:.*No registration for peer .*\(IPaddr: <HOST>\).*$
            ^.*res_pjsip_registrar\.c.*Endpoint.*: Registration.*failed for '<HOST>.*' - Authentication failed.*$
            ^.*res_pjsip\.c.*Request from '<HOST>' failed for '.*' \(callid: .*\) - Failed to authenticate.*$

ignoreregex =
EOF

# Create Asterisk jail configuration with GENEROUS limits.. FreePBX is strange about SIP Registrations,
# so we need to be lenient. (This especially applies if you use Wildix IP Phones)
cat > /etc/fail2ban/jail.d/asterisk.local <<'EOF'
# FreePBX Fail2ban Configuration with GENEROUS limits
# Protects against brute force while avoiding false positives from legitimate phones

[asterisk-pjsip]
enabled = true
port = 5060,5061
protocol = udp,tcp
filter = asterisk-pjsip
logpath = /var/log/asterisk/full
          /var/log/asterisk/messages

# GENEROUS LIMITS - Avoids banning legitimate phones with connection issues
# 20 failed attempts in 10 minutes = ban for 1 hour
maxretry = 20
findtime = 600
bantime = 3600

# Use iptables-multiport for better performance
banaction = iptables-multiport
action = %(action_mwl)s

[asterisk-pjsip-ddos]
enabled = true
port = 5060,5061
protocol = udp,tcp
filter = asterisk-pjsip
logpath = /var/log/asterisk/full
          /var/log/asterisk/messages

# Anti-DDoS: More aggressive for obvious flooding attacks
# 40 failed attempts in 60 seconds = ban for 2 hours
maxretry = 40
findtime = 60
bantime = 7200

banaction = iptables-multiport
action = %(action_mwl)s
EOF

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
cat > /etc/update-motd.d/99-pbx-status <<'EOF'
#!/bin/bash
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# System Info
UPTIME=$(uptime -p | sed 's/up //')
IP_ADDR=$(hostname -I | cut -d' ' -f1)
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
RAM_USAGE=$(free -m | awk 'NR==2 {printf "%.1f%%", $3*100/$2 }')

# Asterisk Version (if running)
AST_VERSION=$(asterisk -rx "core show version" 2>/dev/null | head -n1 | awk '{print $2}' || echo "N/A")

# Service Status Check
check_service() {
    systemctl is-active --quiet $1 2>/dev/null && echo -e "${GREEN}●${NC} ONLINE" || echo -e "${RED}●${NC} OFFLINE"
}

ASTERISK_STATUS=$(check_service asterisk)
MARIADB_STATUS=$(check_service mariadb)
APACHE_STATUS=$(check_service apache2)
FAIL2BAN_STATUS=$(check_service fail2ban)

# Display Banner
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}   ARMBIAN PBX - ASTERISK 22 + FREEPBX 17 (ARM64)${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e ""
echo -e " ${YELLOW}Web Interface:${NC}  http://$IP_ADDR/admin"
echo -e " ${YELLOW}System IP:${NC}      $IP_ADDR"
echo -e " ${YELLOW}Uptime:${NC}         $UPTIME"
echo -e " ${YELLOW}Disk / RAM:${NC}     $DISK_USAGE / $RAM_USAGE"
echo -e " ${YELLOW}Asterisk:${NC}       $AST_VERSION"
echo -e ""
echo -e " ${YELLOW}Services:${NC}"
echo -e "   Asterisk PBX:  $ASTERISK_STATUS"
echo -e "   MariaDB:       $MARIADB_STATUS"
echo -e "   Apache Web:    $APACHE_STATUS"
echo -e "   Fail2ban SEC:  $FAIL2BAN_STATUS"
echo -e ""
echo -e "${BLUE}================================================================${NC}"
EOF
chmod +x /etc/update-motd.d/99-pbx-status
rm -f /etc/motd 2>/dev/null  # Remove static motd to avoid duplication

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}            FREEPBX INSTALLATION COMPLETE!              ${NC}"
echo -e "${GREEN}           Access: http://$(hostname -I | cut -d' ' -f1)/admin  ${NC}"
echo -e "${GREEN}========================================================${NC}"

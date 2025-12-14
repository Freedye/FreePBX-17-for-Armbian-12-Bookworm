#!/bin/bash

# ============================================================================
# PROJECT:  Master Armbian PBX Installer (Asterisk 21 + FreePBX 17)
# TARGET:   Debian 12 (Bookworm) - ARM64 / T95 Max+
# NOTE:     FreePBX 17 usa native PHP 8.2 e richiede Node.js 18+
# ============================================================================

# --- 1. CONFIGURAZIONE VARIABILI ---
ASTERISK_VERSION="21.5.0" # Ultima versione stabile 21 al momento
FREEPBX_VERSION="17.0"
DB_ROOT_PASS="armbianpbx" # Password di default per root SQL (la cambieremo alla fine o usa la tua)
LOG_FILE="/var/log/pbx_install.log"
DEBIAN_FRONTEND=noninteractive

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo "Esegui come root!" 
   exit 1
fi

# --- 2. AGGIORNAMENTO SISTEMA ---
log "Aggiornamento dei repository e del sistema..."
apt-get update && apt-get upgrade -y || error "Fallito update del sistema"

# --- 3. INSTALLAZIONE DIPENDENZE BASE E COMPILAZIONE ---
log "Installazione dipendenze di build e tool essenziali..."
# Nota: Debian 12 ha già pacchetti recenti. 
# Includiamo le librerie per Asterisk (SRTP, Jansson, XML, SQLite, Editline, UUID)
apt-get install -y \
    git curl wget vim htop sox build-essential \
    libncurses5-dev libncursesw5-dev libxml2-dev libsqlite3-dev \
    libssl-dev uuid-dev libjansson-dev libedit-dev libxslt1-dev \
    libsrtp2-dev libopus-dev libvorbis-dev libspeex-dev \
    libspeexdsp-dev libgsm1-dev portaudio19-dev \
    unixodbc unixodbc-dev odbcinst libltdl-dev \
    || error "Fallita installazione dipendenze build"

# --- 4. INSTALLAZIONE STACK LAMP (Linux, Apache, MariaDB, PHP) ---
log "Installazione Web Server e Database..."

# Installazione Apache e MariaDB
apt-get install -y apache2 mariadb-server mariadb-client || error "Fallita installazione Apache/MariaDB"

# Installazione PHP 8.2 (Default su Debian 12) e moduli richiesti da FreePBX 17
log "Installazione PHP 8.2 e estensioni..."
apt-get install -y \
    php php-cli php-common php-curl php-gd php-mbstring \
    php-mysql php-soap php-xml php-intl php-zip php-bcmath \
    php-ldap php-pear libapache2-mod-php \
    || error "Fallita installazione PHP"

# --- 5. INSTALLAZIONE NODE.JS ---
# FreePBX 17 richiede Node 18+. Debian 12 include Node 18.13 o sup. nei repo base.
log "Installazione Node.js e NPM (necessari per FreePBX 17)..."
apt-get install -y nodejs npm || error "Fallita installazione Node.js"
log "Versione Node installata: $(node -v)"

# --- 6. CONFIGURAZIONE PRELIMINARE ---

# Abilitazione modulo Rewrite Apache (Fondamentale per FreePBX)
a2enmod rewrite
systemctl restart apache2

# Settaggio basic MariaDB (Secure installation simulata)
# Se il DB non ha password (nuova installazione), la impostiamo.
if mysqladmin -u root password "$DB_ROOT_PASS" 2>/dev/null; then
    log "Password root MariaDB impostata."
else
    log "Password root MariaDB già impostata o errore non critico."
fi

log "Fase 1 completata. Ambiente pronto."

#!/bin/bash

# ============================================================================
# DEPRECATED / ARCHIVE ONLY
# ============================================================================
# This script is NO LONGER USED in the production installation workflow.
# It is preserved here for safekeeping and reference purposes only.
#
# It documents the manual process used to compile Asterisk 21 from source
# to create the artifacts used by the main installer.
# ============================================================================

cd /usr/src

# 1. Download Source
echo "Downloading Asterisk 21..."
wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-21-current.tar.gz
tar xvf asterisk-21-current.tar.gz
cd asterisk-21.*

# 2. Download MP3 Source (Required for Music on Hold)
contrib/scripts/get_mp3_source.sh

# 3. Configure Build (Using bundled PJProject is critical)
echo "Configuring build..."
./configure --libdir=/usr/lib --with-pjproject-bundled --with-jansson-bundled

# 4. Module Selection via Menuselect
# Enabling MP3 support and extra sound packages
make menuselect.makeopts
menuselect/menuselect --enable format_mp3 menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-WAV menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ULAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-ALAW menuselect.makeopts
menuselect/menuselect --enable CORE-SOUNDS-EN-GSM menuselect.makeopts
menuselect/menuselect --enable app_macro menuselect.makeopts # Legacy compatibility

# 5. Compile
echo "Starting compilation..."
make -j4

# 6. Install
make install
make samples
make config
ldconfig

echo "Asterisk compiled and installed."

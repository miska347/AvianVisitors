#!/usr/bin/env bash
# Startup entrypoint script for BirdNET-Pi / AvianVisitors Docker container
set -e

echo "Starting BirdNET-Pi / AvianVisitors container..."

# Set global environment variables
export my_dir=/home/birdnet/BirdNET-Pi
export USER=birdnet
export HOME=/home/birdnet

# Create logs directory on the host/mount
mkdir -p /data/logs
chown -R birdnet:birdnet /data/logs

# 1. Initialize birdnet.conf if not present
if [ ! -f /data/birdnet.conf ]; then
  echo "Initializing default birdnet.conf in /data..."
  mkdir -p /etc/birdnet
  export LATITUDE=${LATITUDE:-60.1699}
  export LONGITUDE=${LONGITUDE:-24.9384}
  
  # Run the upstream config installer
  cd /home/birdnet/BirdNET-Pi/scripts
  bash install_config.sh
  
  # Move the generated config to /data
  mv /home/birdnet/BirdNET-Pi/birdnet.conf /data/birdnet.conf
fi

# Ensure /etc/birdnet exists and link configuration
mkdir -p /etc/birdnet
ln -sf /data/birdnet.conf /etc/birdnet/birdnet.conf
chown -R birdnet:birdnet /etc/birdnet

# Source configuration
source /etc/birdnet/birdnet.conf

# Configure Icecast
if [ -f /etc/icecast2/icecast.xml ]; then
  echo "Configuring Icecast..."
  sed -i 's/>admin</>birdnet</g' /etc/icecast2/icecast.xml
  for p in "source-" "relay-" "admin-" "master-" ""; do
    sed -i "s/<${p}password>.*<\/${p}password>/<${p}password>${ICE_PWD:-birdnetpi}<\/${p}password>/g" /etc/icecast2/icecast.xml
  done
  sed -i 's|<!-- <bind-address>.*|<bind-address>127.0.0.1</bind-address>|;s|<!-- <shoutcast-mount>.*|<shoutcast-mount>/stream</shoutcast-mount>|' /etc/icecast2/icecast.xml
  
  # Ensure permissions for birdnet user
  chown -R birdnet:birdnet /etc/icecast2
  mkdir -p /var/log/icecast2
  chown -R birdnet:birdnet /var/log/icecast2
fi

# 2. Initialize database if not present
if [ ! -f /data/birds.db ]; then
  echo "Initializing birds.db in /data..."
  export USER=birdnet
  export HOME=/home/birdnet
  export BIRDNET_USER=birdnet
  
  cd /home/birdnet/BirdNET-Pi/scripts
  bash createdb.sh
  
  # Move the database to /data
  mv /home/birdnet/BirdNET-Pi/scripts/birds.db /data/birds.db
fi

# Link database back to scripts directory
ln -sf /data/birds.db /home/birdnet/BirdNET-Pi/scripts/birds.db
chown birdnet:birdnet /data/birds.db
chmod 664 /data/birds.db

# Symlink all codebase scripts to /usr/local/bin/ (matches install_services.sh behavior)
ln -sf /home/birdnet/BirdNET-Pi/scripts/* /usr/local/bin/

# 3. Setup BirdSongs directories
mkdir -p /data/BirdSongs/StreamData
mkdir -p /data/BirdSongs/Processed
mkdir -p /data/BirdSongs/Extracted
chown -R birdnet:birdnet /data/BirdSongs

# Symlink BirdSongs to birdnet user home directory
ln -sf /data/BirdSongs /home/birdnet/BirdSongs
chown -h birdnet:birdnet /home/birdnet/BirdSongs

# 4. Setup web root structures and links in Extracted directory
export my_dir=/home/birdnet/BirdNET-Pi
export USER=birdnet
export EXTRACTED=/data/BirdSongs/Extracted
export PROCESSED=/data/BirdSongs/Processed
export RECS_DIR=/data/BirdSongs

mkdir -p $EXTRACTED/By_Date
mkdir -p $EXTRACTED/Charts
mkdir -p $PROCESSED
mkdir -p $RECS_DIR/StreamData

# Recreate symlinks for files expected by the dynamic PHP UI
ln -fs $my_dir/exclude_species_list.txt $my_dir/scripts/
ln -fs $my_dir/confirmed_species_list.txt $my_dir/scripts/
ln -fs $my_dir/include_species_list.txt $my_dir/scripts/
ln -fs $my_dir/whitelist_species_list.txt $my_dir/scripts/
ln -fs $my_dir/homepage/* ${EXTRACTED}/

if [ -d $my_dir/avian ]; then
  ln -fs $my_dir/avian ${EXTRACTED}/avian
  ln -fs $my_dir/avian/frontend/index.html ${EXTRACTED}/index.html
  ln -fs $my_dir/avian/frontend/styles.css ${EXTRACTED}/styles.css
  ln -fs $my_dir/avian/frontend/apt.js    ${EXTRACTED}/apt.js
  ln -fs $my_dir/avian/frontend/masks.json ${EXTRACTED}/masks.json
  ln -fs $my_dir/avian/frontend/dims.json  ${EXTRACTED}/dims.json
  ln -fs $my_dir/avian/assets/favicon.png  ${EXTRACTED}/favicon.png
  ln -fs $my_dir/avian/assets/favicon.png  ${EXTRACTED}/favicon.ico
else
  ln -fs $my_dir/homepage/images/favicon.ico ${EXTRACTED}/
fi

ln -fs $my_dir/model/labels.txt ${my_dir}/scripts/
ln -fs $my_dir/scripts ${EXTRACTED}/
ln -fs $my_dir/scripts/play.php ${EXTRACTED}/
ln -fs $my_dir/scripts/spectrogram.php ${EXTRACTED}/
ln -fs $my_dir/scripts/overview.php ${EXTRACTED}/
ln -fs $my_dir/scripts/stats.php ${EXTRACTED}/
ln -fs $my_dir/scripts/todays_detections.php ${EXTRACTED}/
ln -fs $my_dir/scripts/history.php ${EXTRACTED}/
ln -fs $my_dir/scripts/weekly_report.php ${EXTRACTED}/

# Ensure all workspace file permissions are correct
chown -R birdnet:birdnet /home/birdnet/BirdNET-Pi
chown -R birdnet:birdnet /data

# 5. Build/Configure Caddyfile using the project's own update_caddyfile.sh script
echo "Configuring Caddyfile..."
# Make sure PHP-FPM socket directory exists
mkdir -p /run/php
chown -R birdnet:birdnet /run/php

# Find installed PHP-FPM binary
PHP_FPM_BIN=$(ls /usr/sbin/php-fpm* /usr/sbin/php*-fpm 2>/dev/null | head -n1)
if [ -z "$PHP_FPM_BIN" ]; then
  echo "ERROR: PHP-FPM binary not found!"
  exit 1
fi
echo "Using PHP-FPM binary: $PHP_FPM_BIN"
# Create generic symlink for supervisord
ln -sf "$PHP_FPM_BIN" /usr/local/bin/php-fpm

# Start PHP-FPM temporarily so update_caddyfile.sh can detect the socket path
/usr/local/bin/php-fpm -D

# Run the update_caddyfile.sh script as root (it internally runs caddy validate/format)
bash /home/birdnet/BirdNET-Pi/scripts/update_caddyfile.sh

# Stop the temporary php-fpm daemon
pkill -f php-fpm || true
rm -f /run/php/php*.sock
sleep 1

# 6. Check if a custom command was passed to the container
if [ "$#" -gt 0 ]; then
  echo "Running custom command: $*"
  # Set user home context and run as birdnet if running a test or python script
  if [ "$1" = "pytest" ] || [[ "$1" == *"python"* ]]; then
    exec sudo -u birdnet HOME=/home/birdnet PATH=$PATH "$@"
  else
    exec "$@"
  fi
fi

# 7. Start supervisord to launch and monitor all background processes
echo "Launching supervisor..."
exec supervisord -c /etc/supervisor/supervisord.conf


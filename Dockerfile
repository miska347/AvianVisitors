FROM python:3.11-slim

# Avoid prompts from apt during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install curl, gnupg and software-properties-common for adding repositories
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Add Caddy stable repository
RUN curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

# Install all system-level dependencies for BirdNET-Pi web UI and python audio analysis
RUN apt-get update && apt-get install -y --no-install-recommends \
    caddy \
    php \
    php-fpm \
    php-sqlite3 \
    php-curl \
    php-xml \
    php-zip \
    php-mbstring \
    php-gd \
    php-cli \
    php-common \
    sqlite3 \
    jq \
    ffmpeg \
    sox \
    libsox-fmt-mp3 \
    alsa-utils \
    pulseaudio \
    icecast2 \
    dbus \
    wget \
    unzip \
    bc \
    sudo \
    lsof \
    supervisor \
    git \
    inotify-tools \
    procps \
    libsndfile1 \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user 'birdnet' and allow passwordless sudo
RUN useradd -m -s /bin/bash -u 1000 birdnet && \
    usermod -aG audio,video birdnet && \
    echo "birdnet ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Configure PHP-FPM to run as the 'birdnet' user (wildcard matches any installed php version)
RUN sed -i 's/user = www-data/user = birdnet/g' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's/group = www-data/group = birdnet/g' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's/listen.owner = www-data/listen.owner = birdnet/g' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's/listen.group = www-data/listen.group = birdnet/g' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's/;clear_env = no/clear_env = no/g' /etc/php/*/fpm/pool.d/www.conf && \
    sed -i 's/;catch_workers_output = yes/catch_workers_output = yes/g' /etc/php/*/fpm/pool.d/www.conf

# Pre-install python packages for faster builds (leverages Docker cache layer)
COPY requirements.txt /tmp/
COPY avian/scripts/requirements.txt /tmp/avian/scripts/
RUN sed -i 's/rembg>=2.0.76/rembg[cli]>=2.0.50,<2.0.76/' /tmp/avian/scripts/requirements.txt && echo "filetype" >> /tmp/avian/scripts/requirements.txt
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /tmp/requirements.txt -r /tmp/avian/scripts/requirements.txt && \
    ln -s /usr/local/bin/rembg /usr/local/bin/rembg-cli


# Copy codebase
COPY . /home/birdnet/BirdNET-Pi/
RUN chown -R birdnet:birdnet /home/birdnet

# Set up mock scripts and configurations (copied to multiple bin paths to intercept absolute calls like /bin/systemctl)
COPY docker/bin/systemctl /usr/local/bin/systemctl
COPY docker/bin/systemctl /bin/systemctl
COPY docker/bin/systemctl /usr/bin/systemctl

COPY docker/bin/journalctl /usr/local/bin/journalctl
COPY docker/bin/journalctl /bin/journalctl
COPY docker/bin/journalctl /usr/bin/journalctl

COPY docker/bin/timedatectl /usr/local/bin/timedatectl
COPY docker/bin/timedatectl /bin/timedatectl
COPY docker/bin/timedatectl /usr/bin/timedatectl

COPY docker/bin/reboot /usr/local/bin/reboot
COPY docker/bin/reboot /usr/sbin/reboot
COPY docker/bin/reboot /bin/reboot
COPY docker/bin/reboot /usr/bin/reboot

COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# Grant execute permission to scripts
RUN chmod +x /usr/local/bin/systemctl /bin/systemctl /usr/bin/systemctl \
             /usr/local/bin/journalctl /bin/journalctl /usr/bin/journalctl \
             /usr/local/bin/timedatectl /bin/timedatectl /usr/bin/timedatectl \
             /usr/local/bin/reboot /usr/sbin/reboot /bin/reboot /usr/bin/reboot \
             /usr/local/bin/entrypoint.sh


# Declare volume mount
VOLUME /data

# Expose ports: Caddy serves Web UI + proxies all background services through port 80
EXPOSE 80

WORKDIR /home/birdnet/BirdNET-Pi

# Launch system services via entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM ubuntu:22.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install SLURM build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    curl \
    bzip2 \
    gcc \
    g++ \
    make \
    autoconf \
    automake \
    libtool \
    libssl-dev \
    libmunge-dev \
    libmunge2 \
    munge \
    mariadb-client \
    default-libmysqlclient-dev \
    libpam0g-dev \
    libnuma-dev \
    libhwloc-dev \
    liblua5.3-dev \
    libreadline-dev \
    zlib1g-dev \
    libbz2-dev \
    libcurl4-openssl-dev \
    libjson-c-dev \
    libyaml-dev \
    libfreeipmi-dev \
    libsysfs-dev \
    libgtk-3-dev \
    libgtk2.0-dev \
    libpam0g-dev \
    libnuma-dev \
    liblz4-dev \
    libzstd-dev \
    python3-dev \
    python3-pip \
    git \
    systemd \
    dbus \
    && rm -rf /var/lib/apt/lists/*

# Build SLURM from source to get all components including slurmdbd
# Using SLURM 23.11.4 (latest stable)
ENV SLURM_VERSION=23.11.4
ENV SLURM_USER=slurm
ENV SLURM_UID=1000
ENV SLURM_GROUP=slurm
ENV SLURM_GID=1000

# Create slurm user
RUN groupadd -r -g ${SLURM_GID} ${SLURM_GROUP} && \
    useradd -r -g ${SLURM_GROUP} -u ${SLURM_UID} -s /bin/bash -d /var/lib/slurm ${SLURM_USER}

# Download and build SLURM
WORKDIR /tmp
RUN wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2 && \
    tar -xjf slurm-${SLURM_VERSION}.tar.bz2 && \
    cd slurm-${SLURM_VERSION} && \
    ./configure --prefix=/usr --sysconfdir=/etc/slurm --localstatedir=/var --enable-pam --disable-cgroup && \
    make -j$(nproc) && \
    make install && \
    cd / && \
    rm -rf /tmp/slurm-${SLURM_VERSION}* && \
    rm -f /usr/lib/slurm/*cgroup* && \
    ldconfig

# Systemd unit for slurmd
RUN mkdir -p /etc/systemd/system && \
    printf '%s\n' \
    "[Unit]" \
    "Description=Slurm Node Daemon" \
    "After=network.target munge.service" \
    "" \
    "[Service]" \
    "Type=simple" \
    "User=slurm" \
    "Group=slurm" \
    "ExecStart=/usr/sbin/slurmd -D" \
    "Restart=always" \
    "" \
    "[Install]" \
    "WantedBy=multi-user.target" \
    > /etc/systemd/system/slurmd.service && \
    systemctl enable slurmd.service || true

# Create necessary directories first
RUN mkdir -p /var/spool/slurmctld \
    /var/spool/slurmd \
    /var/spool/slurmdbd \
    /var/log/slurm \
    /etc/slurm

# Create SLURM user (if it doesn't exist)
RUN id -u slurm 2>/dev/null || useradd -r -s /bin/bash -d /var/lib/slurm slurm

# Set ownership
RUN chown -R slurm:slurm /var/spool/slurm* /var/log/slurm || true

# Copy configuration files
COPY slurmdbd.conf /tmp/slurmdbd.conf
COPY slurm.conf /tmp/slurm.conf
COPY cgroup.conf /tmp/cgroup.conf
COPY slurmd-wrapper.sh /usr/local/bin/slurmd-wrapper.sh
COPY create-stub-cgroup.sh /tmp/create-stub-cgroup.sh
# Move and set correct ownership in one step, create stub cgroup plugin
RUN mv /tmp/slurmdbd.conf /etc/slurm/slurmdbd.conf && \
    mv /tmp/slurm.conf /etc/slurm/slurm.conf && \
    mv /tmp/cgroup.conf /etc/slurm/cgroup.conf && \
    chmod +x /usr/local/bin/slurmd-wrapper.sh && \
    chmod +x /tmp/create-stub-cgroup.sh && \
    /tmp/create-stub-cgroup.sh && \
    chown slurm:slurm /etc/slurm/slurmdbd.conf /etc/slurm/slurm.conf /etc/slurm/cgroup.conf && \
    chmod 600 /etc/slurm/slurmdbd.conf && \
    chmod 644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf

# Set working directory
WORKDIR /etc/slurm

# Default command (will be overridden in docker-compose)
CMD ["bash"]


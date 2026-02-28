FROM ruby:3.4.1-bullseye

# Install dependencies
#RUN apt-get update && apt-get install -y --no-install-recommends \
#    build-essential nodejs postgresql-client \
#    bash emacs docker.io \
#    wget git openssh-client mailutils netcat-openbsd pigz \
#    sqlite3 postgresql libboost-all-dev yarn \
#    openjdk-11-jre-headless curl \
#    linux-headers-amd64 \
#    libsqlite3-dev entr \
#    tar gzip bzip2 zlib1g-dev \
#    libpq-dev \
#    watchman \
#    && apt-get clean \
#    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    nodejs \
    postgresql-client \
    bash \
    emacs \
    docker.io \
    wget \
    git \
    openssh-client \
    mailutils \
    netcat-openbsd \
    pigz \
    sqlite3 \
    postgresql-client \
    libpq-dev \
    libsqlite3-dev \
    libboost-dev \
    yarn \
    openjdk-11-jre \
    curl \
    libmunge-dev \
    libmunge2 \
    munge \
    bzip2 \
    autoconf \
    automake \
    libtool \
    libssl-dev \
    libpam0g-dev \
    libhdf5-dev && \
    rm -rf /var/lib/apt/lists/*



#RUN echo "relayhost = mail.epfl.ch" >> /etc/postfix/main.cf
#RUN /etc/init.d/postfix start

ARG BOOST_VERSION=1.75.0
ARG BOOST_DIR=boost_1_75_0
ENV BOOST_VERSION ${BOOST_VERSION}

# Install HDF5 in a single step to maintain proper context but prevent library conflicts
COPY lib/hdf5-1.10.6-linux-centos7-x86_64-shared.tar.gz /tmp/hdf5.tar.gz
WORKDIR /tmp
RUN tar -zxvf hdf5.tar.gz && \
    cd hdf5-1.10.6-linux-centos7-x86_64-shared/bin && \
    ./h5redeploy -force && \
    cd /tmp && \
    # Remove the conflicting zlib from HDF5 to prevent conflicts with system zlib
    rm -f hdf5-1.10.6-linux-centos7-x86_64-shared/lib/libz.so* && \
    rm hdf5.tar.gz

# Create proper directories for HDF5 and use system libz
RUN mkdir -p /usr/local/hdf5 && \
    cp -r /tmp/hdf5-1.10.6-linux-centos7-x86_64-shared/* /usr/local/hdf5/ && \
    rm -rf /tmp/hdf5-1.10.6-linux-centos7-x86_64-shared

ENV LD_LIBRARY_PATH=/usr/local/hdf5/lib/
ENV PATH=$PATH:/usr/local/hdf5/bin

# Install Boost from source if needed
RUN wget http://downloads.sourceforge.net/project/boost/boost/${BOOST_VERSION}/${BOOST_DIR}.tar.bz2 \
    && tar --bzip2 -xf ${BOOST_DIR}.tar.bz2 \
    && cd ${BOOST_DIR} \
    && ./bootstrap.sh \
    && ./b2 --without-python --prefix=/usr -j 4 link=shared runtime-link=shared install \
    && cd .. \
    && rm -rf ${BOOST_DIR} ${BOOST_DIR}.tar.bz2

# Build SLURM client tools from source to match host version
ARG SLURM_VERSION=22.05.9
WORKDIR /tmp
RUN wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2 && \
    tar -xjf slurm-${SLURM_VERSION}.tar.bz2 && \
    cd slurm-${SLURM_VERSION} && \
    ./configure --prefix=/usr --sysconfdir=/etc/slurm --localstatedir=/var --enable-pam --disable-cgroup && \
    make -j"$(nproc)" && \
    make install && \
    cd / && \
    rm -rf /tmp/slurm-${SLURM_VERSION}* && \
    ldconfig

# Install Rails
RUN gem install rails

# Add custom R-packages
WORKDIR /app

## comment these 3 lines for the first build
COPY src/Gemfile ./
# COPY src/Gemfile.lock ./
RUN bundle install

# Copy package.json and yarn.lock and install node dependencies - comment first line if first build
# For now, we're just creating an empty package.json to satisfy Yarn
#RUN echo '{}' > package.json
#COPY src/package.json ./
#COPY src/yarn.lock ./
#RUN yarn --version && yarn

# Add node_modules/.bin to PATH so that installed binaries (e.g., esbuild, sass) are accessible.
ENV PATH ./node_modules/.bin:$PATH

# Add Rails app
COPY src/. ./

#Add extra libraries and utils
COPY ./lib/* ./lib/

RUN mkdir /var/log/nginx

# Create rvmuser to match host user (for proper file permissions)
ENV USER=rvmuser USER_ID=1006 USER_GID=1006

# Create user and group
RUN groupadd --gid "${USER_GID}" "${USER}" && \
    useradd \
      --uid ${USER_ID} \
      --gid ${USER_GID} \
      --create-home \
      --shell /bin/bash \
      "${USER}"

# Ensure SLURM service user exists for client config parsing (SlurmUser=slurm).
RUN if ! getent group slurm >/dev/null; then groupadd --system slurm; fi && \
    if ! id -u slurm >/dev/null 2>&1; then \
      useradd --system --gid slurm --home /var/lib/slurm --shell /usr/sbin/nologin slurm; \
    fi && \
    mkdir -p /var/lib/slurm && \
    chown slurm:slurm /var/lib/slurm

# Ensure docker group exists with GID 985 to match host (for Docker socket access)
# Remove existing docker group if it exists with wrong GID, then recreate with correct GID
RUN groupdel docker 2>/dev/null || true && \
    groupadd --gid 985 docker || true

# Add user to docker and munge groups
# munge group allows reading munge.key for SLURM authentication
# docker group (GID 985) allows access to Docker socket
RUN usermod -a -G docker,munge "${USER}"

# Ensure bundle directory is writable by rvmuser (needed for bundle install in start.sh)
RUN chown -R "${USER}:${USER}" /usr/local/bundle || true

# Create /run/munge directory and prepare for munge key copy
# The munge key will be mounted from host at runtime, we'll copy it in start.sh
RUN mkdir -p /run/munge /var/log/munge && \
    chmod 755 /run/munge && \
    chmod 700 /var/log/munge && \
    chown -R "${USER}:${USER}" /run/munge /var/log/munge || true

# Note: We don't switch to USER here because docker-compose.test.yml sets user: "1006:1006"
# This allows the container to start as rvmuser while still being able to switch to root if needed

CMD ["bash", "start.sh"]

#USER ${USER}

LABEL maintainer="Fabrice David <fabrice.david@epfl.ch>"

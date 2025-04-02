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
    curl && \
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

#ENV USER=rvmuser USER_ID=1006 USER_GID=1006

# now creating user
#RUN groupadd --gid "${USER_GID}" "${USER}" && \
#    useradd \
#      --uid ${USER_ID} \
#      --gid ${USER_GID} \
#      --create-home \
#      --shell /bin/bash \
#${USER}

#RUN chown -R ${USER} /

#RUN usermod -a -G docker "${USER}"

#USER ${USER}

CMD ["bash", "start.sh"]

#USER ${USER}

LABEL maintainer="Fabrice David <fabrice.david@epfl.ch>"

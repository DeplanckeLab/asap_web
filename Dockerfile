FROM ruby:3.4.1-alpine

RUN apk update && apk add build-base nodejs postgresql-dev bash emacs docker shadow wget git openssh mailx netcat-openbsd pigz sqlite postgresql boost boost-dev yarn
RUN apk add openjdk8-jre curl #default-jre default-jdk
#RUN echo "relayhost = mail.epfl.ch" >> /etc/postfix/main.cf
#RUN /etc/init.d/postfix start

ARG BOOST_VERSION=1.75.0
ARG BOOST_DIR=boost_1_75_0
ENV BOOST_VERSION ${BOOST_VERSION}

#install HDF5
COPY lib/hdf5-1.10.6-linux-centos7-x86_64-shared.tar.gz hdf5.tar.gz
RUN tar -zxf hdf5.tar.gz
ENV LD_LIBRARY_PATH=/hdf5-1.10.6-linux-centos7-x86_64-gcc485-shared/lib/
ENV PATH=$PATH:/hdf5-1.10.6-linux-centos7-x86_64-gcc485-shared/bin
RUN cd /hdf5-1.10.6-linux-centos7-x86_64-shared/bin && ./h5redeploy -force && cd / && rm hdf5.tar.gz && rm -rf hdf5-1.10.6-linux-centos7-x86_64-shared


RUN apk add --no-cache --virtual .build-dependencies \
    linux-headers \
    && wget http://downloads.sourceforge.net/project/boost/boost/${BOOST_VERSION}/${BOOST_DIR}.tar.bz2 \
    && tar --bzip2 -xf ${BOOST_DIR}.tar.bz2 \
    && cd ${BOOST_DIR} \
    && ./bootstrap.sh \
    && ./b2 --without-python --prefix=/usr -j 4 link=shared runtime-link=shared install \
   # && cd .. && rm -rf ${BOOST_DIR} ${BOOST_DIR}.tar.bz2 \
    && apk del .build-dependencies

# Install Rails
RUN gem install rails

# Add custom R-packages
WORKDIR /app

## comment these 3 lines for the first build
 COPY src/Gemfile ./
# COPY src/Gemfile.lock ./
RUN bundle install

# Copy package.json and yarn.lock and install node dependencies - comment first line if first build
#COPY src/package.json ./
#COPY src/yarn.lock ./
RUN yarn install

# Add node_modules/.bin to PATH so that installed binaries (e.g., esbuild, sass) are accessible.
ENV PATH ./node_modules/.bin:$PATH

# Add Rails app
RUN echo "dummy"
COPY src/. ./

#Add extra libraries and utils
COPY ./lib/* ./lib/

RUN mkdir /var/log/nginx


#RUN apk-install sudo
#### add dockerroot group
#RUN groupdel docker
#RUN groupadd --gid 985 docker

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

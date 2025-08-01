########
# base #
########

# Specify the opensciencegrid/software-base image tag
ARG BASE_OS=el9
ARG BASE_YUM_REPO=release
ARG BASE_OSG_SERIES=24

FROM opensciencegrid/software-base:$BASE_OSG_SERIES-$BASE_OS-$BASE_YUM_REPO
LABEL maintainer "OSG Software <help@osg-htc.org>"

# previous args have gone out of scope
ARG BASE_OS=el9
ARG BASE_YUM_REPO=release
ARG BASE_OSG_SERIES=23

# Ensure that the 'condor' UID/GID matches across containers
RUN groupadd -g 64 -r condor && \
    useradd -r -g condor -d /var/lib/condor -s /sbin/nologin \
      -u 64 -c "Owner of HTCondor Daemons" condor && \
    # HACK: create missing /var/log/osg (SOFTWARE-5808) \
    mkdir -p /var/log/osg /var/lib/osg /etc/osg

RUN if [[ $BASE_YUM_REPO == 'release' ]]; then \
        yum install -y --enablerepo=osg-upcoming-testing condor \
                                                         htcondor-ce; \
    fi && \
    yum install -y osg-ce \
                   # FIXME: avoid htcondor-ce-collector conflict
                   git \
                   openssh-clients \
                   sudo \
                   wget \
                   certbot \
                   perl-LWP-Protocol-https \
                   # ^^^ for fetch-crl, in the rare case that the CA forces HTTPS
                   patch && \
    yum clean all && \
    rm -rf /var/cache/yum/

COPY etc/osg/image-config.d/* /etc/osg/image-config.d/
COPY etc/condor-ce/config.d/* /usr/share/condor-ce/config.d/
COPY usr/local/bin/* /usr/local/bin/
COPY etc/supervisord.d/* /etc/supervisord.d/

# Create the dir for CE-generated IDTOKENS used by glideins
# to advertise back to the CE collector (SOFTWARE-5556)
RUN CE_IDTOKEN_DIR=/usr/share/condor-ce/glidein-tokens; \
    mkdir -p "$CE_IDTOKEN_DIR" \
    && chown condor: "$CE_IDTOKEN_DIR"

# SOFTWARE-6149: auto-detect osg-configure changes
# Also do the bad thing of overwriting the existing cron job for fetch-crl
COPY etc/cron.d/* /etc/cron.d/
RUN chmod 644 /etc/cron.d/*

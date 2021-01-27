# Specify the opensciencegrid/software-base image tag
ARG SW_BASE_TAG=fresh

FROM opensciencegrid/software-base:$SW_BASE_TAG

LABEL maintainer "OSG Software <help@opensciencegrid.org>"

# Ensure that the 'condor' UID/GID matches across containers
RUN groupadd -g 64 -r condor && \
    useradd -r -g condor -d /var/lib/condor -s /sbin/nologin \
      -u 64 -c "Owner of HTCondor Daemons" condor

RUN yum install -y --enablerepo=osg-testing \
                   --enablerepo=osg-upcoming-testing \
                   osg-ce-bosco \
                   htcondor-ce-view \
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

# do the bad thing of overwriting the existing cron job for fetch-crl
ADD etc/cron.d/fetch-crl /etc/cron.d/fetch-crl
RUN chmod 644 /etc/cron.d/fetch-crl

# HACK: override condor_ce_jobmetrics from SOFTWARE-4183 until it is released in
# HTCondor-CE.
COPY overrides/condor_ce_jobmetrics /usr/share/condor-ce/condor_ce_jobmetrics

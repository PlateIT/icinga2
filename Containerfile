###################################################################################
# Multi-stage Containerfile for the Icinga 2 runtime image                        #
# 1) base: build Icinga 2 and assemble the runtime filesystem                     #
# 2) final: publish the final minimal image from the prepared rootfs             #
###################################################################################

ARG INSTALL_ROOT=/tmp/rootfs
ARG ROCKY_TAG=9
ARG ICINGA_RUNTIME_DEPS="hostname bash-completion nagios-plugins-all openssl-libs boost curl"
ARG ICINGA_BUILD_DEPS="cmake make gcc-c++ bison flex openssl-devel boost-devel systemd-devel libstdc++-devel bzip2-devel xz-devel zlib-devel libzstd-devel shadow-utils"

#############################
# Base image build
#############################
FROM rockylinux:${ROCKY_TAG} AS base

ARG ROCKY_TAG
ARG INSTALL_ROOT
ARG ICINGA_RUNTIME_DEPS
ARG ICINGA_BUILD_DEPS

RUN mkdir -p ${INSTALL_ROOT}

RUN dnf install -y epel-release && \
	dnf config-manager --set-enabled crb && \
	dnf install -y ${ICINGA_BUILD_DEPS} && \
	dnf clean all

# Runtime-only dependencies and OpenShift-friendly runtime layout.
RUN dnf install --installroot ${INSTALL_ROOT} \
		--releasever=${ROCKY_TAG} \
		--setopt install_weak_deps=false --nodocs -y \
		${ICINGA_RUNTIME_DEPS} && \
	dnf --installroot ${INSTALL_ROOT} clean all && \
	rm -rf ${INSTALL_ROOT}/var/cache/*

RUN useradd -R ${INSTALL_ROOT} -c "icinga" -s /sbin/nologin -g root icinga

RUN mkdir -p ${INSTALL_ROOT}/tmp && chmod 1777 ${INSTALL_ROOT}/tmp

COPY tools/container/entrypoint.sh /tmp/entrypoint.sh
COPY tools/container/entrypoint_functions.sh /tmp/entrypoint_functions.sh

RUN --mount=type=bind,source=.,target=/icinga2,readonly \
	cmake -S /icinga2 -B /tmp/icinga2/release \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_INSTALL_PREFIX=/usr \
		-DCMAKE_INSTALL_SYSCONFDIR=/etc \
		-DCMAKE_INSTALL_LOCALSTATEDIR=/var \
		-DICINGA2_CONFIGDIR=/icinga/etc \
		-DICINGA2_CACHEDIR=/icinga/cache \
		-DICINGA2_DATADIR=/icinga/lib \
		-DICINGA2_LOGDIR=/icinga/log \
		-DICINGA2_SPOOLDIR=/icinga/spool \
		-DICINGA2_INITRUNDIR=/run/icinga2 \
		-DICINGA2_PLUGINDIR=/usr/lib64/nagios/plugins \
		-DICINGA2_USER=icinga \
		-DICINGA2_GROUP=root \
		-DICINGA2_COMMAND_GROUP=root \
		-DICINGA2_WITH_MYSQL=OFF \
		-DICINGA2_WITH_PGSQL=OFF \
		-DICINGA2_WITH_CHECKER=ON \
		-DICINGA2_WITH_COMPAT=OFF \
		-DICINGA2_WITH_LIVESTATUS=OFF \
		-DICINGA2_WITH_NOTIFICATION=OFF \
		-DICINGA2_WITH_PERFDATA=ON \
        -DICINGA2_WITH_ICINGADB=ON \
		-DICINGA2_UNITY_BUILD=OFF \
		-DUSE_SYSTEMD=OFF \
		-DICINGA2_GIT_VERSION_INFO=OFF && \
	cmake --build /tmp/icinga2/release --parallel "$(nproc)" && \
	DESTDIR=${INSTALL_ROOT} cmake --install /tmp/icinga2/release

RUN mkdir -p \
		${INSTALL_ROOT}/{run/icinga2,usr/libexec} && \
	cp -a ${INSTALL_ROOT}/icinga ${INSTALL_ROOT}/icinga-init && \
	install -m 0755 /tmp/entrypoint.sh \
		${INSTALL_ROOT}/usr/libexec/icinga2-container-entrypoint.sh && \
	install -m 0755 /tmp/entrypoint_functions.sh \
		${INSTALL_ROOT}/usr/libexec/icinga2-container-functions.sh && \
	chown -R 0:0 \
		${INSTALL_ROOT}/{run/icinga2,icinga,icinga-init} && \
	chmod -R g=u \
		${INSTALL_ROOT}/{run/icinga2,icinga,icinga-init} && \
	rm -rf ${INSTALL_ROOT}/usr/share/{doc,man}

#############################
# Final image
#############################

FROM scratch
LABEL org.opencontainers.image.title="icinga-container"
LABEL org.opencontainers.image.description="Final image (base runtime + source-built Icinga 2)"
LABEL org.opencontainers.image.source="https://github.com/PlateIT/icinga2"

ARG INSTALL_ROOT

COPY --from=base ${INSTALL_ROOT}/ /

VOLUME ["/icinga"]

ENTRYPOINT ["/usr/libexec/icinga2-container-entrypoint.sh"]

FROM debian:13-slim

LABEL maintainer="support@ip2location.com"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y wget unzip sudo gnupg postgresql \
	&& rm -rf /var/lib/apt/lists/*

ADD app/main.sh /main.sh
ADD app/update.sh /update.sh
ADD app/entrypoint.sh /entrypoint.sh
RUN chmod 755 /*.sh

VOLUME ["/var/log/postgresql", "/var/lib/postgresql"]

EXPOSE 5432

ENTRYPOINT ["/entrypoint.sh"]

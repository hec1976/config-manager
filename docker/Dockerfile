FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    perl libmojolicious-perl libjson-maybexs-perl liblog-log4perl-perl \
    libnet-cidr-perl libipc-run-perl make git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY bin/config-manager.pl /app/bin/config-manager.pl
COPY global.json /app/global.json
COPY configs.json /app/configs.json
COPY backup /app/backup
COPY tmp /app/tmp

EXPOSE 8080
ENV API_TOKEN=changeme

CMD ["/app/bin/config-manager.pl", "daemon", "-l", "http://0.0.0.0:8080"]

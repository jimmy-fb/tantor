FROM ubuntu:22.04

LABEL maintainer="Tantor Kafka VAPT Scanner"
LABEL description="Containerized Kafka Cluster VAPT Scanner with all required tools"

ENV DEBIAN_FRONTEND=noninteractive
ENV KAFKA_VERSION=3.7.0
ENV SCALA_VERSION=2.13

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    wget \
    nmap \
    openssl \
    jq \
    ca-certificates \
    netcat-openbsd \
    dnsutils \
    openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install kcat
RUN apt-get update && apt-get install -y --no-install-recommends kafkacat \
    && rm -rf /var/lib/apt/lists/* \
    || (curl -sL https://github.com/edenhill/kcat/releases/download/1.7.1/kcat-1.7.1-linux-amd64 -o /usr/local/bin/kcat && chmod +x /usr/local/bin/kcat)

# Install Kafka CLI tools
RUN mkdir -p /opt/kafka && \
    curl -sL "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" \
    | tar xz -C /opt/kafka --strip-components=1 || \
    curl -sL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" \
    | tar xz -C /opt/kafka --strip-components=1

ENV KAFKA_HOME=/opt/kafka
ENV PATH="${KAFKA_HOME}/bin:${PATH}"

# Copy scanner scripts
WORKDIR /app
COPY run-kafka-vapt.sh /app/
COPY checks/ /app/checks/
COPY templates/ /app/templates/

RUN chmod +x /app/run-kafka-vapt.sh

# Output directory
RUN mkdir -p /reports
VOLUME ["/reports"]

ENTRYPOINT ["/app/run-kafka-vapt.sh"]

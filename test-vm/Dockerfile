FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    sudo \
    openjdk-17-jre-headless \
    wget \
    curl \
    net-tools \
    iproute2 \
    systemctl \
    tar \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Configure SSH
RUN mkdir /var/run/sshd
RUN echo 'root:tantor123' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Create kafka-friendly dirs
RUN mkdir -p /opt /var/lib/kafka /var/log/kafka

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]

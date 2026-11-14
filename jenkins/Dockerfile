FROM jenkins/jenkins:lts-jdk25

USER root

ARG MAVEN_VERSION=3.9.9
ARG NODE_MAJOR=22

# Outils de base
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg wget git unzip lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Maven
RUN curl -fsSL https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
      | tar -xz -C /opt \
    && ln -s /opt/apache-maven-${MAVEN_VERSION} /opt/maven \
    && ln -s /opt/maven/bin/mvn /usr/local/bin/mvn
ENV MAVEN_HOME=/opt/maven
# Supprime les avertissements Java 25 sur l'accès natif (bibliothèque Jansi de Maven)
ENV MAVEN_OPTS="--enable-native-access=ALL-UNNAMED"

# Node.js + npm (NodeSource)
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Trivy (dépôt officiel Aqua Security)
RUN curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
      | gpg --dearmor -o /usr/share/keyrings/trivy.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
      > /etc/apt/sources.list.d/trivy.list \
    && apt-get update && apt-get install -y --no-install-recommends trivy \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI + Docker Compose (dépôt officiel Docker).
# Seul le client est installé : le démon est celui de la machine hôte,
# joint via le socket /var/run/docker.sock monté par docker-compose.yml.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Plugin docker-rollout (déploiement sans coupure, voir spikes/traefik-rollout)
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL https://raw.githubusercontent.com/wowu/docker-rollout/main/docker-rollout \
      -o /usr/local/lib/docker/cli-plugins/docker-rollout \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-rollout

USER jenkins

# Plugins : déjà installés dans le volume jenkins_home (installés depuis l'interface).
# On ne les retélécharge pas au build (réseau instable). Pour une installation neuve,
# réactiver les deux lignes ci-dessous (la liste est dans plugins.txt) :
# COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
# RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

FROM node:18-alpine

WORKDIR /app

# Copier les fichiers de dépendances
COPY package.json .

# Installer les dépendances nécessaires au runtime
RUN apk add --no-cache su-exec docker-cli \
    && npm install --production \
    && npm cache clean --force

# Copier le code source
COPY server.js .
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Préparer le répertoire de données avec des permissions prévisibles
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
    && mkdir -p /data \
    && chown node:node /data \
    && chmod 775 /data

# Exposer le port interne
EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "server.js"]

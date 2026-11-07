FROM nginx:alpine

ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION}

COPY default.conf /etc/nginx/conf.d/default.conf

# La page affiche la version de l'application et le nom du conteneur qui répond.
# Cela permet de voir, pendant le déploiement, quel conteneur sert la requête.
CMD ["/bin/sh", "-c", "echo \"Application ${APP_VERSION} - conteneur $(hostname)\" > /usr/share/nginx/html/index.html && exec nginx -g 'daemon off;'"]

# Dockerfile for RosarioSIS
# https://www.rosariosis.org/
# Best Dockerfile practices: https://docs.docker.com/develop/develop-images/dockerfile_best-practices/
# Lint Dockerfile: https://hadolint.github.io/hadolint/

# https://hub.docker.com/_/php/tags?name=apache
FROM php:8.1-apache-bookworm

LABEL maintainer="François Jacquet <francoisjacquet@users.noreply.github.com>"

ENV DBTYPE=postgresql \
    PGHOST=db \
    PGUSER=rosario \
    PGPASSWORD=rosariopwd \
    PGDATABASE=rosariosis \
    PGPORT=5432 \
    ROSARIOSIS_YEAR=2024 \
    ROSARIOSIS_LANG='en_US'

# Install postgresql-client, sendmail, nano editor, locales
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-client sendmail nano locales;

# Download and install wkhtmltopdf (avoid direct installation via apt, saves 115M :)
RUN curl -L https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb \
        --output wkhtmltox_0.12.6.1-3.bookworm_amd64.deb; \
    apt-get install -y --no-install-recommends ./wkhtmltox_0.12.6.1-3.bookworm_amd64.deb; \
    rm wkhtmltox_0.12.6.1-3.bookworm_amd64.deb;

# Set the SHELL option -o pipefail before RUN with a pipe in it
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install PHP extensions build dependencies
# Note: $savedAptMark var must be assigned & used in the same RUN command.
RUN savedAptMark="$(apt-mark showmanual)"; \
    apt-get install -y --no-install-recommends \
        libicu-dev libpq-dev libjpeg-dev libpng-dev libwebp-dev libldap2-dev libzip-dev libonig-dev; \
    \
    # Install PHP extensions (curl, mbstring & xml are already included).
    docker-php-ext-configure gd --with-jpeg --with-webp; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    docker-php-ext-configure ldap --with-libdir="lib/$debMultiarch"; \
    docker-php-ext-install -j$(nproc) gd pgsql pdo_pgsql gettext intl zip ldap; \
    \
    # Reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    extDir="$(php -r 'echo ini_get("extension_dir");')"; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    # Remove compilers & dev libraries
    apt-mark auto autoconf dpkg-dev g++ gcc libc6-dev make; \
    ldd "$extDir"/*.so \
        | awk '/=>/ { print $3 }' \
        | sort -u \
        | xargs -r dpkg-query -S \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*;

# Set recommended PHP.ini settings
RUN { \
    echo 'max_execution_time = 240'; \
    echo 'max_input_vars = 4000'; \
    echo 'memory_limit = 512M'; \
    echo 'session.gc_maxlifetime = 3600'; \
    echo 'upload_max_filesize = 50M'; \
    echo 'post_max_size = 51M'; \
} > /usr/local/etc/php/conf.d/rosariosis-recommended.ini
# Set recommended PHP error logging
RUN { \
# https://www.php.net/manual/en/errorfunc.constants.php
    echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
    echo 'display_errors = Off'; \
    echo 'display_startup_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'error_log = /dev/stderr'; \
    echo 'log_errors_max_len = 1024'; \
    echo 'ignore_repeated_errors = On'; \
    echo 'ignore_repeated_source = Off'; \
    echo 'html_errors = Off'; \
} > /usr/local/etc/php/conf.d/error-logging.ini

# Use php.ini-production
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

# Enable Apache mod_rewrite for .htaccess
RUN a2enmod rewrite

# Download and extract rosariosis
ENV ROSARIOSIS_VERSION 'v12.6'

# Set the SHELL option -o pipefail before RUN with a pipe in it
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN mkdir /usr/src/rosariosis && \
    curl -L https://gitlab.com/francoisjacquet/rosariosis/-/archive/${ROSARIOSIS_VERSION}/rosariosis-${ROSARIOSIS_VERSION}.tar.gz \
    | tar xz --strip-components=1 -C /usr/src/rosariosis

# Copy our configuration files.
COPY conf/config.inc.php /usr/src/rosariosis/config.inc.php
COPY bin/init /init

EXPOSE 80

ENTRYPOINT ["/init"]
CMD ["apache2-foreground"]

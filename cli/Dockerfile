ARG PHP_VERSION=8.5

FROM php:${PHP_VERSION}-cli-bookworm

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

RUN apt update && apt install -y git unzip libzip-dev libicu-dev \
    && apt autoremove && apt clean

RUN pecl install redis && docker-php-ext-enable redis
RUN docker-php-ext-install zip && docker-php-ext-enable zip
RUN docker-php-ext-install pdo_mysql && docker-php-ext-enable pdo_mysql
RUN docker-php-ext-install intl && docker-php-ext-enable intl

WORKDIR /var/www/html

RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && php composer-setup.php

RUN mv composer.phar /usr/local/bin/composer

RUN mkdir /var/www/.composer && chmod -R 777 /var/www/.composer

RUN mkdir -p /var/www/.config/psysh && chmod -R 777 /var/www/.config/psysh

USER www-data

#!/usr/bin/env bash

tag="tenancy-queue-test-cli"
php="8.5"

docker build --build-arg PHP_VERSION=$php -t $tag .

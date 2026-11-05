#!/usr/bin/env bash

# Sets up the "alternative config" mentioned here https://github.com/archtechx/tenancy/issues/1260#issuecomment-2572951587

set -e

docker run --rm -v .:/var/www/html tenancy-queue-test-cli bash setup/alternative/_alternative_setup.sh

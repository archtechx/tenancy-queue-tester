#!/usr/bin/env bash

set -e

cd src/

rm config/cache.php
cp ../setup/alternative/cache.php config/cache.php

rm config/database.php
cp ../setup/alternative/database.php config/database.php

rm app/Providers/AppServiceProvider.php
cp ../setup/alternative/AppServiceProvider.php app/Providers/AppServiceProvider.php

if [ -f vendor/stancl/tenancy/src/Bootstrappers/PersistentQueueTenancyBootstrapper.php ]; then
    sed -i 's/QueueTenancyBootstrapper/PersistentQueueTenancyBootstrapper/g' config/tenancy.php
fi

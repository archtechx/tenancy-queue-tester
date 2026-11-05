#!/usr/bin/env bash

set -e

composer global require laravel/installer
~/.composer/vendor/laravel/installer/bin/laravel new --no-interaction --database=sqlite --git src/

cd src/

# If a specific Laravel version is desired
# composer require -W laravel/framework:11.15.0

composer config minimum-stability dev
composer require "stancl/tenancy:$TENANCY_VERSION"

php artisan tenancy:install --no-interaction
php artisan migrate

rm bootstrap/providers.php
cp ../setup/providers.php bootstrap/providers.php

cp ../setup/Tenant_base.php app/Models/Tenant.php
if [ ! -f vendor/stancl/tenancy/src/Contracts/TenantWithDatabase.php ]; then
    sed -i 's/use Stancl\\Tenancy\\Contracts\\TenantWithDatabase/use Stancl\\Tenancy\\Database\\Contracts\\TenantWithDatabase/' app/Models/Tenant.php
fi

sed -i 's/QUEUE_CONNECTION=database/QUEUE_CONNECTION=redis/' .env
sed -i 's/REDIS_HOST=127.0.0.1/REDIS_HOST=redis/' .env
sed -i 's/CACHE_STORE=database/CACHE_STORE=redis/' .env
sed -i 's/Stancl\\Tenancy\\Database\\Models\\Tenant/App\\Models\\Tenant/' config/tenancy.php
sed -i 's/.*RedisTenancyBootstrapper::class.*/        \\Stancl\\Tenancy\\Bootstrappers\\RedisTenancyBootstrapper::class,/' config/tenancy.php
sed -i 's/'\''prefixed_connections'\'' => \[.*$/'\''prefixed_connections'\'' => [ '\''cache'\'',/' config/tenancy.php
echo "REDIS_QUEUE_CONNECTION=queue" >> .env

rm config/database.php
cp ../setup/database.php config/database.php

cp database/migrations/*create_users*.php database/migrations/tenant

mkdir app/Jobs
cp ../setup/FooJob.php app/Jobs/FooJob.php
cp ../setup/LogAbcJob.php app/Jobs/LogAbcJob.php

rm app/Providers/AppServiceProvider.php
cp ../setup/AppServiceProvider.php app/Providers/AppServiceProvider.php

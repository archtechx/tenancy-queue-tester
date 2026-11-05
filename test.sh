#!/usr/bin/env bash

set -e

PERSISTENT=${PERSISTENT:-"0"}
FORCEREFRESH=${FORCEREFRESH:-"1"} # No config needed for this from 3.8.5/4.0 on

assert_queue_worker_running() {
   if docker compose ps -a --format '{{.Status}}' queue | grep -q "Exited"; then
       echo "ERR: Queue worker has exited!"
       docker compose logs queue
       exit 1
   fi
}

assert_queue_worker_exited() {
   if ! docker compose ps -a --format '{{.Status}}' queue | grep -q "Exited"; then
       echo "ERR: Queue worker has NOT exited!"
       docker compose logs queue
       exit 1
   fi
}

assert_no_queue_failures() {
    assert_queue_worker_running
    if docker compose logs queue -n 2 | grep -q "FAIL"; then
        echo "ERR: Queue failures detected in logs"
        exit 1
    fi
}

assert_tenant_users() {
    assert_no_queue_failures
    local tenant=$1
    local expected_count=$2
    test "$(sqlite3 src/database/tenant${tenant}.sqlite 'SELECT count(*) from users')" -eq "$expected_count" || { echo "ERR: Tenant DB $tenant expects $expected_count user(s)."; exit 1; }
}

assert_central_users() {
    assert_no_queue_failures
    local expected_count=$1
    test "$(sqlite3 src/database/database.sqlite 'SELECT count(*) from users')" -eq "$expected_count" || { echo "ERR: Central DB expects $expected_count user(s)."; exit 1; }
}

without_queue_assertions() {
    # Store the original function
    local original_assert_no_queue_failures=$(declare -f assert_no_queue_failures)

    assert_no_queue_failures() { :; }

    # Run the provided command with its arguments
    "$@"

    # Restore the original function
    eval "$original_assert_no_queue_failures"
}

dispatch_central_job() {
    echo "Dispatching job from central context..."
    docker compose exec -T queue php artisan tinker --execute "dispatch(new App\Jobs\FooJob);"
    sleep 5
}

dispatch_tenant_job() {
    local tenant=$1
    echo "Dispatching job from tenant ${tenant} context..."
    docker compose exec -T queue php artisan tinker --execute "App\\Models\\Tenant::find('${tenant}')->run(function () { dispatch(new App\Jobs\FooJob); });"
    sleep 5
}

expect_worker_context() {
    expected_context="$1"

    actual_context=$(cat src/jobprocessed_context)

    if [ "$actual_context" = "$expected_context" ]; then
        echo "OK: JobProcessed context is $expected_context"
    else
        if [ "$PERSISTENT" -eq 1 ]; then
            echo "ERR: JobProcessed context is NOT $expected_context"
            exit 1
        else
            echo "WARN: JobProcessed context is NOT $expected_context"
        fi
    fi
}

###################################### SETUP ######################################

echo "" > src/abc
echo "" > src/sync_context
chmod 777 src/abc src/sync_context
# These files weren't created by the host, but by docker, so we make sure the container also deletes them
# to prevent permissions issues in various environments.
docker compose run --rm queue bash -c 'rm -f database/tenantfoo.sqlite database/tenantbar.sqlite'

docker compose up -d redis # in case it's not running - the below setup code needs Redis to be running

docker compose run --rm queue php artisan migrate:fresh >/dev/null
docker compose run --rm queue php artisan tinker -v --execute "App\\Models\\Tenant::create(['id' => 'foo', 'tenancy_db_name' => 'tenantfoo.sqlite']);App\\Models\\Tenant::create(['id' => 'bar', 'tenancy_db_name' => 'tenantbar.sqlite']);"

docker compose down; docker compose up -d --wait
docker compose logs -f queue &

# Kill any log watchers that may still be alive
trap "docker compose stop queue" EXIT

echo "Setup complete, starting tests..."

################### BASIC PHASE: Assert jobs use the right context ###################
echo
echo "-------- BASIC PHASE --------"
echo

dispatch_tenant_job foo
assert_tenant_users foo 1
assert_tenant_users bar 0
assert_central_users 0
echo "OK: User created in tenant foo"
expect_worker_context tenant_foo

# Assert that the worker correctly distinguishes not just between tenant and central
# contexts, but also between different tenants.
dispatch_tenant_job bar
assert_tenant_users foo 1
assert_tenant_users bar 1
assert_central_users 0
echo "OK: User created in tenant bar"
expect_worker_context tenant_bar

dispatch_central_job
assert_tenant_users foo 1
assert_tenant_users bar 1
assert_central_users 1
echo "OK: User created in central"
expect_worker_context central

############# RESTART PHASE: Assert the worker always responds to signals #############
echo
echo "-------- RESTART PHASE --------"
echo

echo "Running queue:restart (after a central job)..."
docker compose exec -T queue php artisan queue:restart >/dev/null
sleep 5
assert_queue_worker_exited
echo "OK: Queue worker has exited"

echo "Starting queue worker again..."
docker compose restart queue
sleep 5
docker compose logs -f queue &

echo

dispatch_tenant_job foo
# IMPORTANT:
# If the worker remains in the tenant context after running a job
# it not only fails the final assertion here by not responding to queue:restart.
# It ALSO prematurely restarts right here! See https://github.com/archtechx/tenancy/issues/1229#issuecomment-2566111616
# However, we're not too interested in checking for an extra restart, so we skip
# queue assertions here and only check that the job executed correctly.
# Then, if the queue worker has shut down, we simply start it up again and continue
# with the tests. That said, if the warning has been printed, it should be pretty much
# guaranteed that the assertion about queue:restart post-tenant job will fail too.
without_queue_assertions assert_tenant_users foo 2
without_queue_assertions assert_central_users 1
echo "OK: User created in tenant foo"
expect_worker_context tenant_foo

if docker compose ps -a --format '{{.Status}}' queue | grep -q "Exited"; then
    echo "WARN: Queue worker restarted after running a tenant job post-restart (https://github.com/archtechx/tenancy/issues/1229#issuecomment-2566111616), following assertions will likely fail."
    docker compose start queue # Start the worker back up
    sleep 5
    docker compose logs -f queue &
else
    echo "OK: No extra restart took place"
fi

# Following the above, we also want to check if this only happens the first
# time a job is dispatched for a tenant (with central illuminate:queue:restart) filled
# and fills the TENANT's illuminate:queue:restart from then on, or if this happens on
# future jobs of that tenant as well.

# This time, just to add more context, we can try to dispatch a central job first
# in case it changes anything. But odds are that in broken setups we'll see both warnings.
dispatch_central_job
without_queue_assertions assert_tenant_users foo 2
without_queue_assertions assert_central_users 2
echo "OK: User created in central"
expect_worker_context central

dispatch_tenant_job foo
without_queue_assertions assert_tenant_users foo 3
without_queue_assertions assert_central_users 2
echo "OK: User created in tenant foo"
expect_worker_context tenant_foo

if docker compose ps -a --format '{{.Status}}' queue | grep -q "Exited"; then
    echo "WARN: ANOTHER extra restart took place after running a tenant job"
    docker compose start queue # Start the worker back up
    sleep 5
    docker compose logs -f queue &
else
    echo "OK: No second extra restart took place"
fi

# We have to clear the central illuminate:queue:restart value here
# to make the last assertion work, because if the previous WARNs were
# triggered, that means the following *tenant job dispatch* will trigger
# a restart as well.
# -n 1 = DB number for cache connection, configured in setup/database.php
docker compose exec redis redis-cli -n 1 DEL laravel_database_illuminate:queue:restart >/dev/null

# Also make the queue worker reload the value from cache
docker compose restart queue
# restart doesn't kill log watchers, so we don't need to create another one

# Finally, we dispatch a tenant job *immediately* before a restart.
dispatch_tenant_job foo
assert_tenant_users foo 4
assert_central_users 2
echo "OK: User created in tenant foo"
expect_worker_context tenant_foo

echo "Running queue:restart (after a tenant job)..."
docker compose exec -T queue php artisan queue:restart >/dev/null
sleep 5
assert_queue_worker_exited
echo "OK: Queue worker has exited"

############# SYNC PHASE: Assert that dispatching sync jobs doesn't affect outer context #############
echo
echo "-------- SYNC PHASE --------"
echo

# The only thing we can check here is that dispatching a job doesn't revert the context to central
# when executed synchronously.

docker compose run --rm queue php artisan tinker -v --execute "tenancy()->initialize('foo'); App\Jobs\FooJob::dispatchSync(); file_put_contents('sync_context', tenant() ? ('tenant_' . tenant('id')) : 'central');"
without_queue_assertions assert_tenant_users foo 5
without_queue_assertions assert_tenant_users bar 1
without_queue_assertions assert_central_users 2

if grep -q 'tenant_foo' src/sync_context; then
    echo "OK: Sync dispatch preserved context"
else
    echo "ERR: Sync dispatch changed context"
    exit 1
fi

######## REFRESH PHASE: Assert that the worker doesn't hold on to an outdated tenant instance ########
echo
echo "-------- REFRESH PHASE --------"
echo

docker compose start queue
sleep 5
docker compose logs -f queue &
dispatch_tenant_job bar
assert_tenant_users bar 2
assert_central_users 2
echo "OK: User created in tenant bar"

EXPECTED_ABC=$(openssl rand -base64 12)

docker compose exec -T queue php artisan tinker --execute "\$tenant = App\Models\Tenant::find('bar'); \$tenant->update(['abc' => '${EXPECTED_ABC}']); \$tenant->run(function () { dispatch(new App\Jobs\LogAbcJob); });"
sleep 5

if grep -q "${EXPECTED_ABC}" src/abc; then
    echo "OK: Worker notices changes made to the current tenant outside the worker"
else
    if [ "$FORCEREFRESH" -eq 1 ]; then
        echo "ERR: Worker does NOT notice changes made to the current tenant outside the worker"
        exit 1
    else
        echo "WARN: Worker does NOT notice changes made to the current tenant outside the worker"
    fi
fi

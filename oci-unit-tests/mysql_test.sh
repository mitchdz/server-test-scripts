. $(dirname $0)/helper/test_helper.sh

# cheat sheet:
#  assertTrue $?
#  assertEquals 1 2
#  oneTimeSetUp()
#  oneTimeTearDown()
#  setUp() - run before each test
#  tearDown() - run after each test

# The name of the temporary docker network we will create for the
# tests.
readonly DOCKER_NETWORK=mysql_test
readonly DOCKER_IMAGE="${DOCKER_IMAGE:-squeakywheel/mysql:edge}"

oneTimeSetUp() {
    # Make sure we're using the latest OCI image.
    docker pull --quiet "${DOCKER_IMAGE}" > /dev/null

    docker network create $DOCKER_NETWORK > /dev/null 2>&1
}

setUp() {
    password=$(dd if=/dev/urandom bs=1 count=16 2>/dev/null | md5sum | head -c 16)
    id=$$
}

oneTimeTearDown() {
    docker network rm $DOCKER_NETWORK > /dev/null 2>&1
}

tearDown() {
    if [ -n "${container}" ]; then
        stop_container_sync "${container}"
    fi
    if [ -n "${volume}" ]; then
        docker volume rm "${volume}" > /dev/null 2>&1
    fi
}

# Helper function to invoke the mysql server.
# It accepts extra arguments that are then passed to the server.
docker_run_server() {
    docker run \
           --network $DOCKER_NETWORK \
           --rm \
	   -d \
	   --name mysql_test_${id} \
	   "$@" \
	   "${DOCKER_IMAGE}"
}

# Helper function to invoke the mysql client.
#
# The first argument (optional) is always considered to be the user
# that will connect to the server.
#
# The rest of the arguments are passed directly to "mysql".
docker_run_cli() {
    local user=root

    if [ -n "$1" ]; then
	user="$1"
	shift
    fi

    # When it receives the password via CLI, mysql always displays a
    # warning saying that this is insecure.  That's why we filter out
    # these lines in the end.
    docker run \
	   --network $DOCKER_NETWORK \
	   --rm \
	   -i \
	   "${DOCKER_IMAGE}" \
	   mysql -h mysql_test_${id} -u ${user} -p${password} -s "$@" 2>&1 | grep -vxF "mysql: [Warning] Using a password on the command line interface can be insecure."
}

wait_mysql_container_ready() {
    local container="${1}"
    local log="\[System\] \[MY-[0-9]+\] \[Server\] /usr/sbin/mysqld: ready for connections\."
    # mysqld takes a long time to start.
    local timeout=300

    wait_container_ready "${container}" "${log}" "${timeout}"
}

test_list_and_create_databases() {
    debug "Creating mysql container (user root)"
    container=$(docker_run_server -e MYSQL_ROOT_PASSWORD=${password})
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1
    debug "Testing connection as root, looking for \"mysql\" DB"
    # default db is still "mysql"
    out=$(cat <<EOF | docker_run_cli | grep "^mysql"
SHOW DATABASES;
EOF
	  )
    assertEquals "DB listing did not include \"mysql\"" mysql "${out}" || return 1
    # Verify we can create a new DB, since we are root
    test_db="test_db${id}"
    debug "Trying to create a new DB called ${test_db} as user root"
    cat <<EOF | docker_run_cli
CREATE DATABASE ${test_db};
EOF
    # list DB
    debug "Verifying DB ${test_db} was created"
    out=$(cat <<EOF | docker_run_cli | grep "^${test_db}"
SHOW DATABASES;
EOF
	  )
    assertEquals "DB listing did not include \"mysql\"" "${test_db}" "${out}" || return 1
}

test_create_user_and_database() {
    admin_user="user_${id}"
    test_db="test_db_${id}"

    debug "Creating container with MYSQL_USER=${admin_user} and MYSQL_DATABASE=${test_db}"
    container=$(docker_run_server \
        -e MYSQL_USER=${admin_user} \
        -e MYSQL_PASSWORD=${password} \
	-e MYSQL_DATABASE=${test_db} \
	-e MYSQL_ROOT_PASSWORD=${password})
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1

    # list DB
    debug "Verifying DB ${test_db} was created"
    out=$(cat <<EOF | docker_run_cli ${admin_user} | grep "^${test_db}"
SHOW DATABASES;
EOF
	  )
    assertEquals "DB listing did not include \"mysql\"" "${test_db}" "${out}" || return 1
}

test_default_database_name() {
    test_db="test_db_${id}"
    debug "Creating container with MYSQL_DATABASE=${test_db}"
    container=$(docker_run_server \
        -e MYSQL_DATABASE=${test_db} \
        -e MYSQL_ROOT_PASSWORD=${password})
    assertNotNull "Failed to start the container" "${container}" || return 1
    wait_mysql_container_ready "${container}" || return 1
    debug "Checking if database ${test_db} was created"
    out=$(cat <<EOF | docker_run_cli | grep "^${test_db}"
SHOW DATABASES;
EOF
	  )
    assertEquals "Failed to create test database" "${test_db}" "${out}" || return 1
}

test_persistent_volume_keeps_changes() {
# Verify that a container launched with a volume that already has a DB in it
# won't re-initialize it, thus preserving the data.
    debug "Creating persistent volume"
    volume=$(docker volume create)
    assertNotNull "Failed to create a volume" "${volume}" || return 1
    debug "Launching container"
    container=$(docker_run_server \
        -e MYSQL_ROOT_PASSWORD=${password} \
        --mount source=${volume},target=/var/lib/mysql)

    assertNotNull "Failed to start the container" "${container}" || return 1
    # wait for it to be ready
    wait_mysql_container_ready "${container}" || return 1

    # Create test database
    test_db="test_db_${id}"
    debug "Creating test database ${test_db}"
    cat <<EOF | docker_run_cli
CREATE DATABASE ${test_db};
EOF
    out=$(cat <<EOF | docker_run_cli | grep "^${test_db}"
SHOW DATABASES;
EOF
	  )
    assertEquals "Failed to create test database" "${test_db}" "${out}" || return 1

    # create test table
    test_table="test_data_${id}"
    debug "Creating test table ${test_table} with data"
    cat <<EOF | docker_run_cli root "${test_db}"
CREATE TABLE ${test_table} (id INT, description TEXT);
INSERT INTO ${test_table} (id,description) VALUES (${id}, 'hello');
EOF
    # There's no easy way to specify the field delimiter to mysql, so
    # we have to resort to tr.
    out=$(cat <<EOF | docker_run_cli root "${test_db}" | tr '\t' '%'
SELECT * FROM ${test_table};
EOF
	  )
    assertEquals "Failed to verify test table" "${id}%hello" "${out}" || return 1

    # stop container, which deletes it because it was launched with --rm
    stop_container_sync ${container}
    # launch another one with the same volume, and the data we created above
    # must still be there
    # By using the same --name also makes sure the previous container is really
    # gone, otherwise the new one wouldn't start
    debug "Launching new container with same volume"
    container=$(docker_run_server \
        -e MYSQL_ROOT_PASSWORD=${password} \
        --mount source=${volume},target=/var/lib/mysql)

    wait_mysql_container_ready "${container}" || return 1
    # data we created previously should still be there
    debug "Verifying database ${test_db} and table ${test_table} are there with our data"
    out=$(cat <<EOF | docker_run_cli root "${test_db}" | tr '\t' '%'
SELECT * FROM ${test_table};
EOF
	  )
    assertEquals "Failed to verify test table" "${id}%hello" "${out}" || return 1
}

load_shunit2

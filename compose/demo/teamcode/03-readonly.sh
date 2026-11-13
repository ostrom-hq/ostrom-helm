#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Local demo only: the read-only user `ostrom import teamcode` connects as (SELECT on the TeamCode tables, nothing else),
# its password from the environment (TEAMCODE_RO_PASSWORD, in the demo's Compose file).
set -eu
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER 'teamcode_ro'@'%' IDENTIFIED BY '${TEAMCODE_RO_PASSWORD}';
GRANT SELECT ON \`${MYSQL_DATABASE}\`.* TO 'teamcode_ro'@'%';
SQL

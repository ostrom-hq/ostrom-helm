#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Local demo: the fake TeamCode base answers as `ostrom import teamcode` reads it (journey.mjs runs it,
# OSTROM_DEMO_TEAMCODE_CHECK): the read-only user sees the team's rows and cannot write.
set -eu
container=${TEAMCODE_DB_CONTAINER:-ostrom-teamcode-db-1}
q() { docker exec -e MYSQL_PWD=demo-teamcode-ro "$container" mysql -h127.0.0.1 -uteamcode_ro teamcode -N -e "$1" 2>&1; }
counts=$(q "SELECT CONCAT_WS(' ', (SELECT COUNT(*) FROM members WHERE team_id='default'), (SELECT COUNT(*) FROM variants WHERE team_id='default' AND kind='MCP'), (SELECT COUNT(*) FROM variant_assignments WHERE team_id='default' AND kind='MCP'), (SELECT COUNT(*) FROM mcp_tool_policies WHERE team_id='default'), (SELECT COUNT(*) FROM accounts WHERE team_id='default'))" || true)
[ "$counts" = "3 4 5 2 3" ] || { echo "rows (members variants assignments policies accounts): $counts, expected 3 4 5 2 3"; exit 1; }
write=$(q "INSERT INTO teams (id, name) VALUES ('x', 'x')" || true)
case "$write" in *"command denied"*) ;; *) echo "teamcode_ro's write was not refused: $write"; exit 1 ;; esac
echo "team default: 3 members, 4 MCP servers, 5 assignments, 2 tool allowlists, 3 accounts; teamcode_ro reads, cannot write"

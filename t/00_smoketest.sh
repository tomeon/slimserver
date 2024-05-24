#!/usr/bin/env bash

set -euo pipefail

SERVER_LOG=$HOME/server.log
TIMEOUT=30

function retry {
	local -i wait_seconds

	if [[ "${1:--}" = - ]]; then
		wait_seconds=10
	else
		wait_seconds="$1"
	fi

	shift

	until (( (wait_seconds--) == 0 )); do
		"$@" && return
		sleep 1
	done

	return 1
}

function wait_port {
	retry "${1:-}" nc -z localhost "${HTTPPORT:-9000}"
}

function wait_status() {
	# shellcheck disable=SC2317
	_wait_status() {
		local status
		status=$(curl -m1 -SsX POST -d '{"id":0,"params":["",["serverstatus"]],"method":"slim.request"}' "http://localhost:${HTTPPORT:-9000}/jsonrpc.js") || return
		jq . <<<"$status" || return
		jq --raw-output '
			.result.version | if . == null then "JSON RPC call did not return the expected structure\n" | halt_error(1) else . end
		' <<<"$status" 1>/dev/null
	}

	retry "${1:-}" _wait_status
}

function random_tcp_port {
	local -i port
	while port="$RANDOM"; do
		if (( port > 1024 )) && (( port < 65536 )) && ! nc -z localhost "$port"; then
			printf -- '%d' "$port"
			return
		fi
	done
}

# shellcheck disable=SC2317
function finish {
	if [[ -n "${NODE_PID:-}" ]] && (( NODE_PID > 1 )); then
		kill -9 "$NODE_PID" 2> /dev/null || :
		wait "$NODE_PID" || :
	fi

	cat "$SERVER_LOG" || :
	rm -f "$SERVER_LOG"
}

trap finish EXIT

if ! toplevel="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)"; then
	toplevel_rel="${BASH_SOURCE[0]}/../.."
	if ! toplevel="$(readlink -f "$toplevel_rel" 2>/dev/null)"; then
		if ! toplevel="$(realpath "$toplevel_rel" 2>/dev/null)"; then
			toplevel="${PWD:-$(pwd)}"
		fi
	fi
fi

HTTPPORT="$(random_tcp_port)"

"${toplevel}/slimserver.pl" --httpport="$HTTPPORT" --logfile="$SERVER_LOG" &
NODE_PID="$!"

rc=0
wait_port "$TIMEOUT" || {
	rc="$?"
	echo "Timing out trying to connect to LMS"
	exit "$rc"
}

wait_status "$TIMEOUT" || {
	rc="$?"
	echo "Timing out trying to get an API response from LMS"
	exit "$rc"
}

#!/usr/bin/env bash
# Sync the `local` branch with upstream and install the result.
#
# Usage:
#   scripts/sync-upstream.sh           Full sync. Rebase `local` onto origin/main,
#                                      vet, test, build, install, restart, check.
#   scripts/sync-upstream.sh --check   Dry run. Rebase a copy of `local` in a
#                                      temporary worktree, vet, test and build it.
#                                      Install nothing and restart nothing.
#   scripts/sync-upstream.sh --push    Full sync, then force-push `local` to fork.
#
# A full sync stops on a dirty tree or a rebase conflict. A failed test runs
# again once. Known flaky upstream tests that still fail give a warning only.
# The previous binary stays beside the new one as cliproxyapi.previous only
# during the install. The script deletes it after the health check passes.
# If the health check fails, the script puts it back and restarts the service.
set -euo pipefail

GO_VERSION=1.26.10
BRANCH=local
SERVICE=net.lifeiscontent.cliproxyapi
INSTALL_DIR="$HOME/.local/share/cliproxyapi"
BIN="$INSTALL_DIR/cliproxyapi"
CONFIG="$INSTALL_DIR/cliproxyapi.conf"
FLAKY="TestPionMediaRelayBridgesAudioAndDataChannel
TestServerResponsesWebsocketReauthorizesEachTurn
TestClaudeCacheControlDocChecksDoNotMaterializeLargeMessagesArray
TestServiceHeartbeatFailoverDoesNotDrainBlockingScope"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Print "<package> <test|test...>" for each failed package in a go test log.
# The test list is empty when no test name is known, for example on a build
# failure or a panic.
failed_tests() {
	awk '
		/^--- FAIL: / { tests = tests (tests ? "|" : "") $3; next }
		/^ok[ \t]/ { tests = "" }
		/^FAIL[ \t]/ { print $2, tests; tests = "" }
	' "$1"
}

# Run go test. Run each failure again once. Stop on a failure that is not
# a known flaky test.
run_tests() {
	local log="$TMP/test.log" retry="$TMP/retry.log" pkg tests t
	local flaky_seen="" broken=""
	if go test ./... 2>&1 | tee "$log"; then
		return 0
	fi
	say "Some tests failed. Running the failed tests again."
	while read -r pkg tests; do
		if go test ${tests:+-run "^(${tests})\$"} "$pkg" >"$retry" 2>&1 </dev/null; then
			say "Passed on the second run: $pkg ${tests}"
			continue
		fi
		cat "$retry"
		tests=$(failed_tests "$retry" | awk '{ print $2 }')
		[ -n "$tests" ] || { broken="$broken $pkg"; continue; }
		for t in ${tests//|/ }; do
			if printf '%s\n' "$FLAKY" | grep -qx "$t"; then
				flaky_seen="$flaky_seen $t"
			else
				broken="$broken $pkg.$t"
			fi
		done
	done < <(failed_tests "$log")
	[ -z "$flaky_seen" ] || say "Known flaky tests failed twice:$flaky_seen"
	[ -z "$broken" ] || die "Tests failed twice:$broken"
}

# Vet, test and build the current directory into $1.
build() {
	local version commit date
	say "Running go vet."
	if ! go vet ./... 2>"$TMP/vet.log"; then
		cat "$TMP/vet.log" >&2
		# Upstream CI does not run vet. Findings in test files give a warning only.
		if grep -v '^#' "$TMP/vet.log" | grep -qv '_test\.go:'; then
			die "go vet found problems outside test files."
		fi
		say "go vet found problems in test files only. Continuing."
	fi
	say "Running go test."
	run_tests
	version="$(git describe --tags --always)-lic"
	commit=$(git rev-parse --short HEAD)
	date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	say "Building $version."
	CGO_ENABLED=1 go build -ldflags="-s -w -X 'main.Version=$version' -X 'main.Commit=$commit' -X 'main.BuildDate=$date'" -o "$1" ./cmd/server
	VERSION=$version
}

# Print server.port from the config, or 8317.
config_port() {
	local port
	port=$(awk '
		/^[^[:space:]#]/ { top = $1 }
		top == "server:" && /^  port:/ { print $2; exit }
	' "$CONFIG")
	printf '%s\n' "${port:-8317}"
}

# Print the first key of access.api-keys from the config.
config_api_key() {
	awk '
		/^[^[:space:]#]/ { top = $1; keys = 0; next }
		top == "access:" && /^  api-keys:/ { keys = 1; next }
		keys && /^  [^[:space:]#-]/ { keys = 0 }
		keys && /^[[:space:]]*- / {
			v = $0
			sub(/^[[:space:]]*- */, "", v)
			if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*/, "", v) }
			else if (v ~ /^\047/) { sub(/^\047/, "", v); sub(/\047.*/, "", v) }
			else { sub(/[[:space:]]+#.*/, "", v); sub(/[[:space:]]+$/, "", v) }
			print v
			exit
		}
	' "$CONFIG"
}

# GET /v1/models until it returns 200, for up to 30 seconds. The key goes to
# curl on stdin, so it is not in argv or in any log.
health_check() {
	local key url code _
	key=$(config_api_key)
	[ -n "$key" ] || die "No access.api-keys entry in $CONFIG."
	url="http://127.0.0.1:$(config_port)/v1/models"
	for _ in $(seq 30); do
		code=$(printf 'Authorization: Bearer %s\n' "$key" |
			curl -s -o /dev/null -w '%{http_code}' -m 5 -H @- "$url" || true)
		if [ "$code" = 200 ]; then
			say "Health check passed: GET $url returned 200."
			return 0
		fi
		sleep 1
	done
	printf 'Health check failed: GET %s returned %s.\n' "$url" "${code:-no response}" >&2
	return 1
}

restart() {
	say "Restarting $SERVICE."
	launchctl kickstart -k "gui/$(id -u)/$SERVICE"
}

check() {
	local wt="$TMP/worktree"
	git worktree add --quiet --detach "$wt" "$BRANCH"
	trap 'cd "$ROOT"; git worktree remove --force "$TMP/worktree"; rm -rf "$TMP"' EXIT
	cd "$wt"
	say "Rebasing a copy of $BRANCH onto origin/main in $wt."
	if ! git rebase --quiet origin/main; then
		git rebase --abort
		die "The rebase has conflicts. Run the full sync to resolve them."
	fi
	build "$TMP/cliproxyapi"
	say "Check passed. A full sync would install $VERSION."
}

sync() {
	local previous="$BIN.previous"
	[ -z "$(git status --porcelain)" ] || die "The working tree is not clean. Commit or stash your changes first."
	say "Rebasing $BRANCH onto origin/main."
	if ! git rebase origin/main "$BRANCH"; then
		die "The rebase stopped on a conflict.
Fix the files, then run 'git add <file>' and 'git rebase --continue'.
After the rebase completes, run this script again.
To cancel, run 'git rebase --abort'.
git rerere records your fixes and uses them again next time."
	fi
	build "$TMP/cliproxyapi"
	say "Copying the current binary to $previous."
	cp -p "$BIN" "$previous"
	say "Installing $VERSION."
	cp "$TMP/cliproxyapi" "$BIN.new"
	chmod 755 "$BIN.new"
	mv -f "$BIN.new" "$BIN"
	restart
	if ! health_check; then
		say "Restoring the previous binary."
		mv -f "$previous" "$BIN"
		restart
		die "The new build failed the health check. The previous binary is back in place."
	fi
	rm -f "$previous"
	say "Installed $VERSION."
}

main() {
	local mode=sync
	case "${1:-}" in
		"") ;;
		--check) mode=check ;;
		--push) mode=push ;;
		*) die "Unknown option: $1. Use --check or --push." ;;
	esac
	ROOT=$(git rev-parse --show-toplevel)
	cd "$ROOT"
	PATH="$(mise where "go@$GO_VERSION")/bin:$PATH"
	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT
	say "Fetching origin and fork."
	git fetch --quiet origin
	git fetch --quiet fork
	if [ "$mode" = check ]; then
		check
		return
	fi
	sync
	if [ "$mode" = push ]; then
		say "Pushing $BRANCH to fork."
		git push --force-with-lease fork "$BRANCH"
	fi
}

# The rebase can rewrite this file while it runs. Bash reads this whole line
# before it runs main, and exit stops it from reading the changed file.
main "$@"; exit $?

#!/bin/sh
# A service that is stopped or restarted from inside its own cgroup
# (patches/tree/018-base-files-service-stop-from-inside.patch).
#
# procd keeps every service in a cgroup of its own; newer versions end all
# processes in it when the service stops. A shell on an SSH session lives in
# dropbear's cgroup, so "/etc/init.d/dropbear restart" typed there used to
# end between the stop and the start, and SSH stayed down.
#
# The test needs a real procd and cgroup v2, so it runs on a router:
#
#   scp -O <patched rc.common> scripts/test-service-self-restart.sh root@<router>:/tmp/
#   ssh root@<router> 'sh /tmp/test-service-self-restart.sh /tmp/rc.common'
#
# The argument is the rc.common to check; without one it is the router's own
# /etc/rc.common. A patched copy is made on a desktop with
#   patch -o rc.common <stock rc.common> patches/tree/018-base-files-service-stop-from-inside.patch
#
# It starts a service of its own (one "sleep", named miwrt-selftest-<pid>,
# init script in /tmp) and stops and restarts only that. No service of the
# router is touched. A procd that does not end the cgroup by itself (OpenWrt
# 25.12) is made to: the test's init script ends the cgroup after the stop,
# as the newer procd does. The first run is a control with the guard taken
# out, and it has to fail; otherwise the test would prove nothing.

set -u

RC=${1:-/etc/rc.common}
NAME=miwrt-selftest-$$
INIT=/tmp/$NAME
DIR=/tmp/$NAME.d
CG=/sys/fs/cgroup/services/$NAME/instance1

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -w /sys/fs/cgroup/cgroup.procs ] || ! command -v ubus >/dev/null 2>&1 ||
   ! ubus list service >/dev/null 2>&1; then
	echo "service self-restart tests: SKIPPED, this machine has no procd with cgroup v2 (run it on a router, see the head of the script)"
	exit 0
fi

[ -r "$RC" ] || fail "cannot read $RC"
grep -q 'procd_leave_cgroup "\$(basename' "$RC" ||
	fail "$RC has no guard (procd_leave_cgroup): give the patched rc.common as the argument"

cleanup() {
	sh "$RC" "$INIT" stop >/dev/null 2>&1
	rm -rf "$INIT" "$DIR"
	rmdir "$CG" "/sys/fs/cgroup/services/$NAME" 2>/dev/null
}
trap 'cleanup' EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$DIR"

cat > "$INIT" <<EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /bin/sleep 86400
	procd_close_instance
}

# what a procd that ends the cgroup on a stop does, for one that does not
service_stopped() {
	[ -n "\${SELFTEST_KILL:-}" ] || return 0
	echo 1 > $CG/cgroup.kill 2>/dev/null
	return 0
}
EOF

# the same rc.common without the call of the guard
sed '/procd_leave_cgroup "\$(basename/d' "$RC" > "$DIR/rc.noguard"
grep -q 'procd_leave_cgroup "\$(basename' "$DIR/rc.noguard" && fail "could not take the guard out for the control run"

main_pid() {
	ubus call service list "{\"name\":\"$NAME\"}" 2>/dev/null |
		jsonfilter -e '@[*].instances[*].pid' 2>/dev/null | head -n 1
}

running() {
	local p
	p=$(main_pid)
	[ -n "$p" ] && [ -d "/proc/$p" ]
}

fresh() {
	sh "$RC" "$INIT" stop >/dev/null 2>&1
	sleep 1
	rm -f "$DIR"/mark.* "$DIR"/cg.*
	sh "$RC" "$INIT" start >/dev/null 2>&1
	local i=0
	# procd's child joins the cgroup a moment after procd has its pid
	while ! running || ! grep -qx "$(main_pid)" "$CG/cgroup.procs" 2>/dev/null; do
		i=$((i + 1))
		[ $i -lt 20 ] || fail "the test service does not start in $CG"
		sleep 1
	done
}

# A "session": a shell inside the service's cgroup that runs the init script
# and goes on afterwards, as a login shell on SSH does.
#   session <rc.common> <action> <kill: 1|""> <orphan: 1|"">
session() {
	cat > "$DIR/session" <<EOF
#!/bin/sh
echo \$\$ > $CG/cgroup.procs || exit 9
cat /proc/\$\$/cgroup > $DIR/cg.before
if [ -n "$4" ]; then
	# started in the background by something that has ended since
	( sleep 1; SELFTEST_KILL=$3 sh $1 $INIT $2; echo \$? > $DIR/mark.caller ) &
	exit 0
fi
SELFTEST_KILL=$3 sh $1 $INIT $2
echo \$? > $DIR/mark.caller
cat /proc/\$\$/cgroup > $DIR/cg.after
echo alive > $DIR/mark.session
EOF
	sh "$DIR/session" </dev/null >/dev/null 2>&1 &
}

wait_for() {
	local i=0
	while [ $i -lt "$2" ]; do
		[ -e "$1" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# ---- does this procd end the cgroup by itself?
fresh
session "$DIR/rc.noguard" restart "" ""
if wait_for "$DIR/mark.session" 6; then
	PROCD_KILLS=no
else
	PROCD_KILLS=yes
fi
echo "this procd ends a stopped service's cgroup by itself: $PROCD_KILLS"

# ---- control: without the guard the restart must not get to its start
fresh
old=$(main_pid)
session "$DIR/rc.noguard" restart 1 ""
wait_for "$DIR/mark.caller" 6 && fail "control: the caller outlived the end of its cgroup; the test cannot tell a guard from none"
new=$(main_pid)
[ -z "$new" ] || [ "$new" = "$old" ] || ! [ -d "/proc/$new" ] ||
	fail "control: the service came back without the guard (pid $new)"
echo "control without the guard: the restart ended half way and the service stayed down, as expected"

# ---- restart from inside
fresh
old=$(main_pid)
session "$RC" restart 1 ""
wait_for "$DIR/mark.session" 15 || fail "restart from inside: the shell that asked for it did not survive"
[ "$(cat "$DIR/mark.caller")" = 0 ] || fail "restart from inside: the init script ended with $(cat "$DIR/mark.caller")"
i=0
while ! running || [ "$(main_pid)" = "$old" ] || ! grep -qx "$(main_pid)" "$CG/cgroup.procs" 2>/dev/null; do
	i=$((i + 1))
	[ $i -lt 10 ] || fail "restart from inside: the service is not running again in its cgroup"
	sleep 1
done
[ -d "/proc/$old" ] && fail "restart from inside: the old process $old is still there"
grep -q "/services/$NAME/" "$DIR/cg.before" || fail "restart from inside: the caller was not in the service's cgroup to begin with"
grep -q "/services/$NAME/" "$DIR/cg.after" && fail "restart from inside: the caller is still in the service's cgroup"
[ "$(cat "$CG/cgroup.procs" | wc -l)" = 1 ] || fail "restart from inside: the new cgroup holds more than the service: $(cat "$CG/cgroup.procs" | tr '\n' ' ')"
[ "$(cat "$CG/cgroup.procs")" = "$(main_pid)" ] || fail "restart from inside: the service's own process is not in its cgroup"
echo "restart from inside: done, the shell that asked for it lives on"

# ---- restart from inside, asked for by a job whose starter has ended
fresh
old=$(main_pid)
session "$RC" restart 1 1
wait_for "$DIR/mark.caller" 15 || fail "restart by a background job: the job did not survive"
[ "$(cat "$DIR/mark.caller")" = 0 ] || fail "restart by a background job: the init script ended with $(cat "$DIR/mark.caller")"
i=0
while ! running || [ "$(main_pid)" = "$old" ]; do
	i=$((i + 1))
	[ $i -lt 10 ] || fail "restart by a background job: the service is not running again"
	sleep 1
done
echo "restart from inside by a background job: done"

# ---- stop from inside: the service stops, and stays stopped
fresh
old=$(main_pid)
session "$RC" stop 1 ""
wait_for "$DIR/mark.session" 15 || fail "stop from inside: the shell that asked for it did not survive"
sleep 1
running && fail "stop from inside: the service is still running"
[ -d "/proc/$old" ] && fail "stop from inside: the process $old is still there"
echo "stop from inside: done"

# ---- the service's own process is never moved, whoever asks
fresh
old=$(main_pid)
grep -q "/services/$NAME/" "/proc/$old/cgroup" || fail "the service's process is not in its cgroup"
( eval "$(sed -n '/^	procd_leave_cgroup() {$/,/^	} 2>\/dev\/null$/p' "$RC")"
  type procd_leave_cgroup >/dev/null 2>&1 || exit 7
  # asked from this shell, which is not in the cgroup: nothing may move
  before=$(cat /proc/$$/cgroup)
  procd_leave_cgroup "$NAME"
  [ "$(cat /proc/$$/cgroup)" = "$before" ] || exit 8
) || fail "a stop from outside the cgroup moved the caller (or the guard could not be read: $?)"
grep -q "/services/$NAME/" "/proc/$old/cgroup" || fail "the service's own process was moved out of its cgroup"

# ---- restart from outside, the everyday case
before=$(cat /proc/$$/cgroup)
sh "$RC" "$INIT" restart >/dev/null 2>&1 || fail "restart from outside failed"
i=0
while ! running || [ "$(main_pid)" = "$old" ]; do
	i=$((i + 1))
	[ $i -lt 10 ] || fail "restart from outside: the service is not running again"
	sleep 1
done
[ "$(cat /proc/$$/cgroup)" = "$before" ] || fail "restart from outside moved the caller to another cgroup"
echo "restart from outside: done, the caller stayed where it was"

echo "service self-restart tests: OK"

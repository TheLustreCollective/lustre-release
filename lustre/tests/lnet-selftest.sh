#!/bin/bash

LUSTRE=${LUSTRE:-$(dirname $0)/..}
. $LUSTRE/tests/test-framework.sh
init_test_env "$@"
init_logging

ALWAYS_EXCEPT="$LNET_SELFTEST_EXCEPT"

if $FORCE_LARGE_NID; then
	always_except LU-19364 smoke
fi

build_test_filter

[ x$LST = x ] && skip_env "lst not found LST=$LST"

# FIXME: what is the reasonable value here?
lst_LOOP=${lst_LOOP:-100000}
lst_CONCR=${lst_CONCR:-"1 2 4 8"}
lst_SIZES=${lst_SIZES:-"4k 8k 256k 1M"}
if [ "$SLOW" = no ]; then
	lst_CONCR="1 8"
	lst_SIZES="4k 1M"
	lst_LOOP=1000
fi

smoke_DURATION=${smoke_DURATION:-1800}
if [ "$SLOW" = no ]; then
	[ $smoke_DURATION -le 300 ] || smoke_DURATION=300
fi

lst_TESTS=${lst_TESTS:-"write read ping"}

# "none" -> LST_BRW_CHECK_NONE
# "full" -> LST_BRW_CHECK_FULL
# "simple" -> LST_BRW_CHECK_SIMPLE
lst_CHECK=${lst_CHECK:-"full"}

lst_FROM=${lst_FROM:-"cs"}

case $lst_CHECK in
	full|simple) check="check=$lst_CHECK";;
	none) check="";;
	*) error Unknown flag $lst_CHECK;;
esac

LOAD_MODULES_REMOTE=true load_modules

nodes=$(tgts_nodes)
lst_SERVERS=${lst_SERVERS:-$(comma_list "$(host_nids_address $nodes $NETTYPE)")}
lst_CLIENTS=${lst_CLIENTS:-$(comma_list "$(host_nids_address $CLIENTS $NETTYPE)")}
interim_umount=false
interim_umount1=false

#
# _restore_mount(): This function calls restore_mount function for "MOUNT" and
# "MOUNT2" paths to mount clients if they were not mounted and were umounted
# in this file earlier.
# Parameter: None
# Returns: None. Exit with error if client mount fails.
#
_restore_mount () {
	if $interim_umount && ! is_mounted $MOUNT; then
		restore_mount $MOUNT || error "Restore $MOUNT failed"
	fi

	if $interim_umount1 && ! is_mounted $MOUNT2; then
		restore_mount $MOUNT2 || error "Restore $MOUNT2 failed"
	fi
}

if local_mode; then
   lst_SERVERS=`hostname`
   lst_CLIENTS=`hostname`
fi

# FIXME: do we really need to unload lustre modules on all nodes?
# bug 19387, comment 9
# unloading lustre modules is not strictly necessary but unmounting
# /mnt/lustre before running lst would be useful:
# 1) because lustre messages clutter logs - we needn't them for testing LNET
# 2) it's theoretically possible that lst tests congest comm paths so tightly
# that mounted lustre wouldn't able to perform some of its background activities
if is_mounted $MOUNT; then
	cleanup_mount $MOUNT || error "Fail to unmount client $MOUNT"
	interim_umount=true
fi

if is_mounted $MOUNT2; then
	cleanup_mount $MOUNT2 || error "Fail to unmount client $MOUNT2"
	interim_umount1=true
fi

lst_prepare () {
	# Workaround for bug 15619
	lst_cleanup_all
	lst_setup_all
}

# make batch
test_smoke_sub () {
	local servers=$1
	local clients=$2

	local nc=$(echo ${clients//,/ } | wc -w)
	local ns=$(echo ${servers//,/ } | wc -w)
	echo '#!/bin/bash'
	echo 'set -e'

	echo 'cleanup () { trap 0; echo killing $1 ... ; kill -9 $1 || true; }'

	echo "$LST new_session --timeo 100000 hh"
	echo "$LST add_group c $(nids_list $clients)"
	echo "$LST add_group s $(nids_list $servers)"
	echo "echo '====================================='"
	echo "echo 'Listing of bad_group should not crash'"
	echo "echo '====================================='"
	echo "$LST list_group s bad_group c"
	echo "$LST add_batch b"

	declare -a tests

	case $lst_FROM in
		c) tests[0]="${nc}:${ns} --from c --to s";;
		s) tests[0]="${ns}:${nc} --from s --to c";;
		cs)tests[0]="${nc}:${ns} --from c --to s"
		   tests[1]="${ns}:${nc} --from s --to c";;
		*) error Unknown flag $lst_FROM;;
	esac

	pre="$LST add_test --batch b --loop $lst_LOOP "
	for t in $lst_TESTS; do
		for s in $lst_SIZES; do
			for c in $lst_CONCR; do
				for ((i=0; i<${#tests[@]}; i++)); do
					echo -n "$pre --concurrency $c"\
						" --distribute ${tests[i]} "
					case $t in
						read|write)
							echo -n "brw $t" \
							" $check size=$s";;
						ping)
							echo -n $t;;
						*) error Unknonwn LST test;;
					esac
					echo
				done
			done
		done
	done

	echo $LST run b
	echo sleep 1
	echo "$LST stat --delay 10 --timeout 10 c s &"
	echo 'pid=$!'
	echo 'trap "cleanup $pid" INT TERM'
	echo sleep $smoke_DURATION
	echo 'cleanup $pid'
}

run_lst () {
	local file=$1

	export LST_SESSION=$$

	# start lst
	bash $file
}

check_lst_err () {
	local log=$1

	grep ^Total $log

	if awk '/^Total.*nodes/ {print $2}' $log | grep -vq '^0$'; then
		_restore_mount
		error 'lst Error found'
	fi
}

test_smoke () {
	lst_prepare

	local servers=$lst_SERVERS
	local clients=$lst_CLIENTS

	local runlst=$TMP/smoke.sh

	local log=$TMP/$tfile.log
	local rc=0

	test_smoke_sub $servers $clients 2>&1 > $runlst

	cat $runlst

	run_lst $runlst | tee $log
	rc=${PIPESTATUS[0]}
	[ $rc = 0 ] || { _restore_mount; error "$runlst failed: $rc"; }

	lst_end_session --verbose | tee -a $log

	# error counters in "lst show_error" should be checked
	check_lst_err $log
	lst_cleanup_all
}
run_test smoke "lst regression test"

# Test rapid session create/destroy cycles with active BRW traffic.
# Reproduces LU-20104 session teardown deadlock: orphaned server RPCs on
# scd_rpc_active list, improper batch drain ordering in sfw_remove_session,
# and zombie session destroy from workitem context (cancel_work_sync
# deadlock on same workqueue).
test_teardown () {
	lst_prepare

	local servers=$lst_SERVERS
	local clients=$lst_CLIENTS
	local nc=$(echo ${clients//,/ } | wc -w)
	local ns=$(echo ${servers//,/ } | wc -w)
	local cycles=5
	local rc=0

	for i in $(seq $cycles); do
		echo "=== Teardown cycle $i/$cycles ==="
		export LST_SESSION=$$

		$LST new_session --timeo 100000 teardown_$i
		$LST add_group c $(nids_list $clients)
		$LST add_group s $(nids_list $servers)
		$LST add_batch b

		$LST add_test --batch b --loop 5000 --concurrency 8 \
			--distribute ${nc}:${ns} --from c --to s \
			brw write $check size=1M
		$LST add_test --batch b --loop 5000 --concurrency 8 \
			--distribute ${nc}:${ns} --from c --to s \
			ping

		$LST run b
		sleep 2

		# end_session must complete without deadlock
		timeout 60 $LST end_session --verbose
		rc=$?
		if [ $rc -eq 124 ]; then
			error "session teardown deadlocked on cycle $i"
		fi
		[ $rc -eq 0 ] || error "end_session failed on cycle $i: rc=$rc"
	done

	lst_cleanup_all
}
run_test teardown "lst session teardown stress (LU-20104)"

# Test BRW with non-zero offsets. Reproduces LU-20104 offset handling bugs:
# 1) brw_client_prep_rpc did not mask offset with ~PAGE_MASK
# 2) brw_client_init allocated bulk without accounting for offset
# 3) No validation that off+len <= LNET_MTU
# On unpatched kernels, off=4096 causes LBUG (nblk != bk_niov) and
# off=2048 size=1M causes NULL page dereference or LASSERT failure.
test_brw_offset () {
	lst_prepare

	local servers=$lst_SERVERS
	local clients=$lst_CLIENTS
	local nc=$(echo ${clients//,/ } | wc -w)
	local ns=$(echo ${servers//,/ } | wc -w)
	local log=$TMP/$tfile.log
	local rc=0

	export LST_SESSION=$$

	$LST new_session --timeo 100000 brw_offset
	$LST add_group c $(nids_list $clients)
	$LST add_group s $(nids_list $servers)

	# Valid offsets with various sizes
	for off in 0 512 1024 2048; do
		for size in 4k 64k; do
			echo "=== BRW read off=$off size=$size ==="
			$LST add_batch b_r_${off}_${size}
			$LST add_test --batch b_r_${off}_${size} \
				--concurrency 4 \
				--distribute ${nc}:${ns} \
				--from c --to s \
				brw read $check size=$size off=$off
			$LST run b_r_${off}_${size}
			$LST stat --delay 1 --count 10 --timeout 5 c s \
				| tee -a $log
			$LST stop b_r_${off}_${size}
		done
	done

	# offset >= PAGE_SIZE triggers nblk mismatch in
	# sfw_create_test_rpc when prep_rpc doesn't mask offset
	echo "=== BRW read off=4096 size=4k (PAGE_SIZE offset) ==="
	$LST add_batch b_page
	$LST add_test --batch b_page \
		--concurrency 4 \
		--distribute ${nc}:${ns} --from c --to s \
		brw read $check size=4k off=4096
	$LST run b_page
	$LST stat --delay 1 --count 10 --timeout 5 c s | tee -a $log
	$LST stop b_page

	# off + len > LNET_MTU exceeds LNET_MAX_IOV pages,
	# should return error and avoid NULL page dereference
	# in srpc_init_bulk
	echo "=== BRW write off=2048 size=1M (off+len > LNET_MTU) ==="
	$LST add_batch b_overflow
	$LST add_test --batch b_overflow \
		--concurrency 2 \
		--distribute ${nc}:${ns} --from c --to s \
		brw write $check size=1M off=2048 && \
		error "off=2048 size=1M should have been rejected"

	lst_end_session --verbose | tee -a $log
	check_lst_err $log
	lst_cleanup_all
}
run_test brw_offset "lst BRW offset handling (LU-20104)"

# Reproduces the LU-20104 workqueue list-corruption race: server-side
# srpc_handle_rpc's abort/shutdown branch calls LNetMDUnlink on the bulk
# and reply MDs after setting wi->swi_state=DONE; the resulting UNLINK
# events run srpc_lnet_ev_handler, which sets ev_fired and calls
# queue_work on the same srpc_wi that's still executing. On the same
# pass through srpc_server_rpc_done the recycle path used to call
# INIT_WORK on a work_struct still pending in the workqueue's list,
# corrupting it ("list_add corruption. prev->next should be next ...").
#
# To hit that race reliably we want:
#   * many in-flight bulk MDs (high concurrency, both directions) so the
#     abort path has many MDs to LNetMDUnlink in close succession,
#   * end_session called while traffic is still ramping (no settle
#     sleep) so MDs are actively in-flight rather than drained,
#   * many cycles to keep rolling the dice.
test_teardown_race () {
	lst_prepare

	local servers=$lst_SERVERS
	local clients=$lst_CLIENTS
	local nc=$(echo ${clients//,/ } | wc -w)
	local ns=$(echo ${servers//,/ } | wc -w)
	local cycles=${LST_TEARDOWN_RACE_CYCLES:-20}
	local rc=0

	for i in $(seq $cycles); do
		echo "=== Teardown-race cycle $i/$cycles ==="
		export LST_SESSION=$$

		$LST new_session --timeo 100000 teardown_race_$i
		$LST add_group c $(nids_list $clients)
		$LST add_group s $(nids_list $servers)
		$LST add_batch b

		# bidirectional brw + ping at high concurrency: maximises the
		# number of bulk + reply MDs the abort path must LNetMDUnlink
		# while the worker is still running srpc_handle_rpc.
		$LST add_test --batch b --loop 10000 --concurrency 32 \
			--distribute ${nc}:${ns} --from c --to s \
			brw write $check size=1M
		$LST add_test --batch b --loop 10000 --concurrency 32 \
			--distribute ${nc}:${ns} --from c --to s \
			brw read $check size=1M
		$LST add_test --batch b --loop 10000 --concurrency 32 \
			--distribute ${nc}:${ns} --from c --to s \
			ping

		$LST run b
		# No settle sleep: end_session must hit while MDs are
		# actively in flight, not after they've drained.

		timeout 60 $LST end_session --verbose
		rc=$?
		if [ $rc -eq 124 ]; then
			error "end_session deadlocked on cycle $i"
		fi
		[ $rc -eq 0 ] || error "end_session failed on cycle $i: rc=$rc"
	done

	lst_cleanup_all
}
run_test teardown_race "lst teardown wq list-corruption race (LU-20104)"

complete_test $SECONDS
_restore_mount
check_and_cleanup_lustre
exit_status

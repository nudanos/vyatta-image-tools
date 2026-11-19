#!/bin/bash
# shellcheck disable=SC2317 # reason: shunit2 calls the tests, and the mocks they define, by name
#
# RAID setup takes its disks as separate words: "sda sdb" from the
# VII_*_ARRAY_DISKS variables, one argument each to setup_raid and on to
# mdadm. None of the RAID path runs in a single-disk install, so these
# tests are the only check that the disk lists still arrive intact.

# run_command records each call, one argument per line, a blank line after
run_command ()
{
    printf '%s\n' "$@" "" >> "${SHUNIT_TMPDIR}/calls"
    return 0
}

fail_exit ()
{
    echo "fail_exit: $*" >> "${SHUNIT_TMPDIR}/calls"
    return 1
}

# the arguments of the recorded call whose first argument is $1
call_args ()
{
    awk -v cmd="$1" 'BEGIN { RS = ""; FS = "\n" } $1 == cmd { print; exit }' \
        "${SHUNIT_TMPDIR}/calls"
}

testSetupRaidPassesEachDiskToMdadm ()
{
    local md
    md=$(setup_raid 1 vRouter sda sdb)
    assertEquals "md device" "md/md-vRouter" "$md"
    local args
    args=$(call_args mdadm)
    assertContains "raid-devices" "$args" "--raid-devices=2"
    assertTrue "/dev/sda is its own argument" "grep -qx /dev/sda <<< '$args'"
    assertTrue "/dev/sdb is its own argument" "grep -qx /dev/sdb <<< '$args'"
    assertFalse "no failure" "grep -q fail_exit '${SHUNIT_TMPDIR}/calls'"
}

testSetupRaidFromAnArrayVariable ()
{
    # as write_to_disk calls it, with the disk list of a VII_ variable
    local VII_LOG_ARRAY_DISKS="sdc sdd sde"
    local md
    md=$(setup_raid_disks 5 LOGS "$VII_LOG_ARRAY_DISKS")
    assertEquals "md device" "md/md-LOGS" "$md"
    assertContains "raid-devices" "$(call_args mdadm)" "--raid-devices=3"
    assertFalse "no failure" "grep -q fail_exit '${SHUNIT_TMPDIR}/calls'"
}

testSizeOfArraySumsItsDisks ()
{
    get_drive_size ()
    {
        case $1 in
            sda) echo 100 ;;
            sdb) echo 250 ;;
            *) echo 0 ;;
        esac
    }
    assertEquals "sum of the members" 350 "$(size_of_array /dev/sda /dev/sdb)"
}

oneTimeSetUp ()
{
    local THIS_DIR
    THIS_DIR="$(cd "$(dirname "${0}")" || exit; pwd -P)"
    vyatta_sbindir="${THIS_DIR}/../scripts"
    export vyatta_sbindir
    # shellcheck disable=SC1091 # reason: the scripts under test, next to this directory
    . "${THIS_DIR}"/../scripts/vyatta-create-partition
    # shellcheck disable=SC1091 # reason: the scripts under test, next to this directory
    . "${THIS_DIR}"/../scripts/vyatta-multiple-partition.functions
}

setUp ()
{
    SHUNIT_TMPDIR=$(mktemp -d)
    : > "${SHUNIT_TMPDIR}/calls"
}

tearDown ()
{
    rm -rf "${SHUNIT_TMPDIR:?}"
}

# load and run shUnit2
# shellcheck disable=SC1091 # reason: shunit2 is a build dependency
. shunit2

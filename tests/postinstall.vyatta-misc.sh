#!/bin/bash

testRun ()
{
    # succeed (don't run) if unconfigured
    TEXT=$(VII_POSTINSTALL_VYATTA_MISC='false' 50-vyatta-misc run)
    assertTrue "Returns true" $?
    assertEquals "" "${TEXT}"

    # fail if missing arguments
    TEXT=$(VII_POSTINSTALL_VYATTA_MISC='true' 50-vyatta-misc run 2>/dev/null)
    assertFalse "Returns false" $?
    #assertEquals "" "${TEXT}"

    # succeed is required directories don't exist
    TEXT=$(VII_POSTINSTALL_VYATTA_MISC='true' 50-vyatta-misc run \
	"${SHUNIT_TMPDIR}" "test")
    assertTrue "Returns false" $?

    mkdir -p "${SHUNIT_TMPDIR}"/opt/vyatta/share/vyatta-op/templates/install
    touch "${SHUNIT_TMPDIR}"/opt/vyatta/share/vyatta-op/templates/install/a.txt
    assertTrue "install directory exists" \
	"[ -d '${SHUNIT_TMPDIR}/opt/vyatta/share/vyatta-op/templates/install' ]"

    # succeed
    TEXT=$(VII_POSTINSTALL_VYATTA_MISC='true' 50-vyatta-misc run \
	"${SHUNIT_TMPDIR}" "test")
    assertTrue "Returns true" $?
    assertEquals "" "${TEXT}"

    # install template directory gone
    assertFalse "install directory exists" \
	"$(test -d "${SHUNIT_TMPDIR}"/opt/vyatta/share/vyatta-op/templates/install; echo $?)"
}

oneTimeSetUp ()
{
    local THIS_DIR
    THIS_DIR="$(cd "$(dirname "${0}")" || exit; pwd -P)"

    vyatta_sbindir="${THIS_DIR}/../scripts"
    export vyatta_sbindir

    # make SUT visible
    PATH="${THIS_DIR}/../postinstall.d:${PATH}"
    export PATH

    # the implementation knows about unittest implementation
    if [ -z "${SHUNIT_TMPDIR}" ] ; then
	SHUNIT_TMPDIR=$(mktemp -d)
	trap 'rm -rf "${SHUNIT_TMPDIR}"' EXIT
    fi
    export SHUNIT_TMPDIR

    export INSTALL_LOG=""

    TMPDIR=${SHUNIT_TMPDIR}
    export TMPDIR
}

tearDown ()
{
    # clean-up after every test
    if [ -n "${SHUNIT_TMPDIR}" ] ; then
	rm -fr "${SHUNIT_TMPDIR:?}"/*
    fi
}

# load and run shUnit2
# shellcheck disable=SC2034 # reason: shunit2 reads it under zsh
[ -n "${ZSH_VERSION:-}" ] && SHUNIT_PARENT=$0
# shellcheck disable=SC1091 # reason: shunit2 is a build dependency
. shunit2

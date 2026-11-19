#!/bin/bash

testRun ()
{
    # succeed (don't run) if unconfigured
    TEXT=$(VII_PREINSTALL_VIRTUALIZATION='false' 10-virtualization run)
    assertTrue "Returns true" $?
    assertEquals "" "${TEXT}"

    # fail if missing arguments
    TEXT=$(VII_PREINSTALL_VIRTUALIZATION='true' 10-virtualization run 2>/dev/null)
    assertFalse "Returns false" $?
    #assertEquals "" "${TEXT}"
}

testVirtualizationInNewImage ()
{
    # the running image has vCPE support
    mkdir -p "${SHUNIT_TMPDIR}/bin" "${SHUNIT_TMPDIR}/cd/live"
    printf '#!/bin/sh\necho "ii  vyatta-virtualization 1.0"\n' > "${SHUNIT_TMPDIR}/bin/dpkg"
    chmod +x "${SHUNIT_TMPDIR}/bin/dpkg"

    # the new image has it too
    echo "ii  vyatta-virtualization 1.1" > "${SHUNIT_TMPDIR}/cd/live/packages.txt"
    PATH="${SHUNIT_TMPDIR}/bin:${PATH}" VII_PREINSTALL_VIRTUALIZATION='true' \
        10-virtualization run "${SHUNIT_TMPDIR}/cd" >/dev/null 2>&1
    assertTrue "new image with vCPE support accepted" $?

    # the new image lacks it
    echo "ii  vyatta-base 1.0" > "${SHUNIT_TMPDIR}/cd/live/packages.txt"
    PATH="${SHUNIT_TMPDIR}/bin:${PATH}" VII_PREINSTALL_VIRTUALIZATION='true' \
        10-virtualization run "${SHUNIT_TMPDIR}/cd" >/dev/null 2>&1
    assertFalse "new image without vCPE support refused" $?
}

oneTimeSetUp ()
{
    local THIS_DIR
    THIS_DIR="$(cd "$(dirname "${0}")" || exit; pwd -P)"

    vyatta_sbindir="${THIS_DIR}/../scripts"
    export vyatta_sbindir

    # make SUT visible
    PATH="${THIS_DIR}/../preinstall.d:${PATH}"
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

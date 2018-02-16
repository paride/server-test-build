#!/bin/bash
# Build a set of packages on a release in a container
#
# Used to test that packages in the archive are still buildable and do
# not fail to build (FTBFS).
#
# Copyright 2018 Canonical Ltd.
# Joshua Powers <josh.powers@canonical.com>
set -eu

APT_CMD="DEBIAN_FRONTEND=noninteractive apt-get --assume-yes"

error() { echo "$@" 1>&2; }

usage() {
    cat <<EOF
Usage: ${0##*/} RELEASE SRC_PACKAGE[s]...
For a supported release, download and build package(s) from the
archive in a container.

Examples:
    * ${0##*/} bionic vim
    * ${0##*/} xenial ant qemu-kvm
    * ${0##*/} bionic exim4 iotop htop pep8 qemu uvtool
EOF
}

bad_usage() { usage 1>&2; [ $# -eq 0 ] || error "$@"; return 1; }

cleanup() {
    if [ "$(lxc list "$NAME" --columns n --format=csv)" == "$NAME" ]; then
        lxc delete --force "$NAME"
    fi
}

check_networking(){
    exec_container sh -c '
        i=0
        while [ $i -lt 60 ]; do
            getent hosts archive.ubuntu.com && exit 0
            sleep 2
        done'

    ret=$?
    if [ "$ret" -ne 0 ]; then
        error "Waiting for network in container '$NAME' failed"
    fi
}

exec_container() {
    lxc exec "$NAME" -- "$@" >/dev/null 2>&1
    return $?
}

launch_container() {
    if [ "$(lxc list "$NAME" --columns n --format=csv)" == "$NAME" ]; then
        lxc delete --force "$NAME"
    fi

    lxc launch ubuntu-daily:"$RELEASE" "$NAME" ||
        error "Failed to start '$RELEASE' container named '$NAME'"

    check_networking "$NAME"

    echo 'Upgrading and installing ubuntu-dev-tools'
    exec_container sh -c "$APT_CMD update"
    exec_container sh -c "$APT_CMD upgrade"
    exec_container sh -c "$APT_CMD install ubuntu-dev-tools"

    lxc snapshot "$NAME" base_image
}


build_package() {
    local package=$1
    shift

    exec_container sh -c "$APT_CMD update"
    exec_container sh -c "$APT_CMD build-dep $package"

    set +e
    START=$(date +%s)
    lxc exec "$NAME" -- sh -c "cd $package-*/ && dpkg-buildpackage -j4 -us -uc" &> "$LOG_DIR/$package.log"
    echo $? > "$LOG_DIR/$package.result"
    END=$(date +%s)
    set -e

    echo $((END-START)) > "$LOG_DIR/$package.time"
}

main () {
    local short_opts="h"
    local long_opts="help"
    local getopt_out=""
    local getopt_out=$(getopt --name "${0##*/}" \
        --options "${short_opts}" --long "${long_opts}" -- "$@") &&
        eval set -- "${getopt_out}" || bad_usage

    local cur=""
    local next=""

        while [ $# -ne 0 ]; do
            cur="${1:-}"; next="${2:-}";
            case "$cur" in
                -h|--help) usage; exit 0;;
                --) shift; break;;
            esac
            shift;
    done

    # Program starts here
    [ $# -gt 1 ] ||
        bad_usage "error: must provide a release and at least one package"
        
    DATE=$(date +%Y%m%d-%H%m%S)
    RELEASE=$1; shift
    NAME=build-$RELEASE-$DATE
    LOG_DIR=logs/$RELEASE-$DATE

    supported_releases=($(distro-info --supported | tr '\r\n' ' '))
    if [[ ! " ${supported_releases[@]} " =~ " $RELEASE " ]]; then
        bad_usage "error: '$RELEASE' is not a supported release"
    fi

    trap cleanup EXIT
    launch_container

    mkdir -p "$LOG_DIR"
    echo "Beginning builds"
    echo "---"

    for package in "$@"; do
        echo "$package"

        lxc restore "$NAME" base_image
        check_networking "$NAME"

        exec_container sh -c "pull-lp-source $package $RELEASE"
        if [ $? -ne 0 ]; then
            echo "skipping: not found in $RELEASE";
            echo -1 > "$LOG_DIR/$package.result"
            continue;
        fi

        build_package "$package"

    done

}

main "$@"
cleanup

# vi: ts=4 expandtab

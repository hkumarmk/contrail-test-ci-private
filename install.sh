#!/bin/bash

CONTRAIL_TEST_CI_REPO=https://github.com/juniper/contrail-test-ci
CONTRAIL_TEST_CI_REF=master
CONTRAIL_TEST_REPO=https://github.com/juniper/contrail-test
CONTRAIL_TEST_REF=master
CONTRAIL_FAB_REPO=https://github.com/juniper/contrail-fabric-utils
CONTRAIL_FAB_REF=master
BASE_DIR=`dirname $(readlink -f $0)`

usage () {
    cat <<EOF
Install or do docker build of Contrail-test and contrail-test-ci

Usage: $0 (install|docker-build) [OPTIONS] (contrail-test|contrail-test-ci)

Subcommands:

install         Install contrail-test/contrail-test-ci
docker-build    Build docker container

Run $0 <Subcommand> -h|--help to get subcommand specific help

EOF
}

function make_dockerfile {
    cat <<'EOF'
FROM hkumar/ubuntu-14.04.2
MAINTAINER Juniper Contrail <contrail@juniper.net>
ARG CONTRAIL_INSTALL_PACKAGE_URL
ARG ENTRY_POINT=docker_entrypoint.sh
ARG SSHPASS
ENV DEBIAN_FRONTEND=noninteractive

EOF

if [[ $CONTRAIL_INSTALL_PACKAGE_URL =~ ^http[s]*:// ]]; then
    cat <<'EOF'
# Just check if $CONTRAIL_INSTALL_PACKAGE_URL is there, if not valid, build will fail
RUN wget -q --spider $CONTRAIL_INSTALL_PACKAGE_URL

# setup contrail-install-packages
RUN wget $CONTRAIL_INSTALL_PACKAGE_URL -O /contrail-install-packages.deb && \
    dpkg -i /contrail-install-packages.deb && \
    rm -f /contrail-install-packages.deb && \
    cd /opt/contrail/contrail_packages/ && ./setup.sh && \
    apt-get install -y python-pip ant python-dev python-novaclient python-neutronclient python-cinderclient \
                    python-contrail patch python-heatclient python-ceilometerclient python-setuptools \
                    libxslt1-dev libz-dev libyaml-dev git python-glanceclient && \
                    rm -fr /opt/contrail/* ; apt-get -y autoremove && apt-get -y clean;

EOF
elif [[ $CONTRAIL_INSTALL_PACKAGE_URL =~ ^ssh[s]*:// ]]; then
    scp_package=1
    if [[ -z $SSHUSER ]]; then
        echo "ERROR! ssh user credentials not given, expected the variables: SSHUSER and SSHPASS" >&2
        exit 1
    fi
    server=` echo $CONTRAIL_INSTALL_PACKAGE_URL | sed 's/ssh:\/\///;s|\/.*||'`
    path=`echo $CONTRAIL_INSTALL_PACKAGE_URL |sed -r 's#ssh://[a-zA-Z0-9_\.\-]+##'`
    cat << EOF

RUN apt-get install -y sshpass && \
    sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SSHUSER}@${server}:${path} /contrail-install-packages.deb && \
    dpkg -i /contrail-install-packages.deb && \
    rm -f /contrail-install-packages.deb && \
    cd /opt/contrail/contrail_packages/ && ./setup.sh && \
    apt-get install -y python-pip ant python-dev python-novaclient python-neutronclient python-cinderclient \
                    python-contrail patch python-heatclient python-ceilometerclient python-setuptools \
                    libxslt1-dev libz-dev libyaml-dev git python-glanceclient && \
                    rm -fr /opt/contrail/* && apt-get -y autoremove && apt-get -y clean
EOF
else
    echo "ERROR, Unknown url format, only http[s], ssh supported" >&2
    exit 1
fi
    # In case of contrail-test, ci should be added in /contrail-test-ci and later merge both
    # /contrail-test-ci and /contrail-test together
    ci_dir='/contrail-test'

    if [[ $build_type == 'contrail-test' ]]; then
        ci_dir='/contrail-test-ci'
        merge_code='cp -RTf /contrail-test-ci /contrail-test; '
        if [[ -f $CONTRAIL_TEST_ARTIFACT ]]; then
            echo -e "ADD $(basename $CONTRAIL_TEST_ARTIFACT) /"
        else
            cat <<EOF
RUN git clone $CONTRAIL_TEST_REPO /contrail-test; \
    cd /contrail-test ; \
    git checkout $CONTRAIL_TEST_REF; \
    git reset --hard; \
    rm -fr .git
EOF
        fi
    elif [[ $build_type == 'contrail-test-ci' && -f $CONTRAIL_TEST_CI_ARTIFACT ]] ; then
        merge_code='mv /contrail-test-ci /contrail-test; '
    fi

    if [[ -f $CONTRAIL_TEST_CI_ARTIFACT ]]; then
        echo -e "ADD $(basename $CONTRAIL_TEST_CI_ARTIFACT) /"
    else
        cat <<EOF
RUN git clone $CONTRAIL_TEST_CI_REPO $ci_dir; \
    cd $ci_dir ; \
    git checkout $CONTRAIL_TEST_CI_REF; \
    git reset --hard; \
    rm -fr .git
EOF
     fi

    if [[ -f $CONTRAIL_FAB_ARTIFACT ]]; then
        echo -e "ADD $(basename $CONTRAIL_FAB_ARTIFACT) /opt/contrail/"
        fab_utils_mv="mv /opt/contrail/fabric-utils /opt/contrail/utils; "
    else
        cat <<EOF
RUN git clone $CONTRAIL_FAB_REPO /opt/contrail/utils; \
    cd /opt/contrail/utils ; \
    git checkout $CONTRAIL_FAB_REF; \
    git reset --hard;
EOF
    fi

    cat <<EOF
RUN  $merge_code $fab_utils_mv cd /contrail-test && pip install --upgrade -r requirements.txt

COPY \$ENTRY_POINT /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

}

docker_build () {
    usage () {
    cat <<EOF
Build Contrail-test and contrail-test-ci docker container

Usage: $0 docker-build [OPTIONS] (contrail-test|contrail-test-ci)

  -h|--help                     Print help message
  --test-repo REPO                Contrail-test git repo, Default: github.com/juniper/contrail-test-ci.git
  --test-ref REF                  Contrail-test git reference - commit id, branch, tag, Default: master
  --fab-repo FAB_REPO           Contrail-fabric-utils git repo
  --fab-ref FAB_REF             Contrail-fabric-utils git reference (commit id, branch, or tag), Default: master
  --ci-repo CI_REPO	            Contrail-test-ci git repo, Default: github.com/juniper/contrail-test.git
  --ci-ref CI_REF               Contrail-test-ci reference (commit id, branch, or tag), Default: master
  --container-tag CONTAINER_TAG Docker container tag, default to contrail-test-ci-<openstack-release>:<contrail-version>
                                    openstack-release and contrail-version is extracted from contrail-install-package name
                                    e.g contrail-test-ci-juno:2.21-105
  --test-artifact ARTIFACT        Contrail test tar file - this tar file will be used instead of git source in case provided
  --ci-artifact CI_ARTICACT     Contrail test ci tar file
  --fab-artifact FAB_ARTIFACT   Contrail-fabric-utils tar file
  -u|--package-url PACKAGE_URL  Contrail-install-packages deb package web url (http:// or https://) or scp path
                                (ssh://<server ip/name/< package path>), if url is provided, the
                                package will be installed and setup local repo.
                                In case of scp, user name and password will be read from environment variables
                                SSHUSER - user name to be used during scp
                                SSHPASS - user password to be used during scp

  -c|--use-cache                Use docker cache for the build
  -e|--export EXPORT_PATH       Export Container image to the path provided

  positional arguments
    Type of build               What to build, valid options are contrail-test, contrail-test-ci

 Example:

  $ $0 docker-build --test-repo https://github.com/hkumarmk/contrail-test --test-ref working
        --ci-repo https://\$GITUSER:\$GITPASS@github.com/juniper/contrail-test-ci -e /tmp/export2
        -u http://nodei16/contrail-install-packages_2.21-105~juno_all.deb contrail-test

  $ export SSHUSER=user1 SSHPASS=password
  $ $0 docker-build --test-repo https://github.com/hkumarmk/contrail-test --test-ref working
        --ci-repo https://\$GITUSER:\$GITPASS@github.com/juniper/contrail-test-ci -e /tmp/export2
        -u ssh://nodei16/var/cache/artifacts/contrail-install-packages_2.21-105~juno_all.deb contrail-test


EOF
    }

    if ! options=$(getopt -o hcu:t:e: -l help,test-artifact:,ci-artifact:,fab-artifact:,use-cache,ci-repo:,ci-ref:,export:,test-repo:,test-ref:,contrail-install-package-url:,fab-repo:,fab-ref:,container-tag: -- "$@"); then
# parse error
        usage
        exit 1
    fi
    eval set -- "$options"

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit;;
            --test-repo) CONTRAIL_TEST_REPO=$2; shift;;
            --test-ref) CONTRAIL_TEST_REF=$2; shift;;
            -u|--package-url) CONTRAIL_INSTALL_PACKAGE_URL=$2; shift;;
            --fab-repo) CONTRAIL_FAB_REPO=$2; shift;;
            --fab-ref) CONTRAIL_FAB_REF=$2; shift;;
            --ci-repo) CONTRAIL_TEST_CI_REPO=$2; shift;;
            --ci-ref) CONTRAIL_TEST_CI_REF=$2; shift;;
            --test-artifact) CONTRAIL_TEST_ARTIFACT=$2; shift;;
            --ci-artifact) CONTRAIL_TEST_CI_ARTIFACT=$2; shift;;
            --fab-artifact) CONTRAIL_FAB_ARTIFACT=$2; shift;;
            -t|--container-tag) CONTAINER_TAG=$2; shift;;
            -c|--use-cache) CACHE=1;;
            -e|--export) EXPORT_PATH=$2; shift;;
            --) :;;
            *) build_type=$1;;
	    esac
	    shift
    done

    if [[ -z $CONTRAIL_INSTALL_PACKAGE_URL ]]; then
        echo "No contrail package url provided"; echo
        usage
        exit 1
    fi

    if [[ -z $CONTAINER_TAG ]]; then
        if [[ $CONTRAIL_INSTALL_PACKAGE_URL =~ (ssh|http|https)*://.*/contrail-install-packages_[0-9\.\-]+~[a-zA-Z]+_all.deb ]]; then
            contrail_version=`echo ${CONTRAIL_INSTALL_PACKAGE_URL##*/} | sed 's/contrail-install-packages_\([0-9\.\-]*\).*/\1/'`
            openstack_release=`echo ${CONTRAIL_INSTALL_PACKAGE_URL##*/} | sed 's/contrail-install-packages_[0-9\.\-]*~\([a-zA-Z]*\).*/\1/'`
            CONTAINER_TAG=${build_type}-${openstack_release}:${contrail_version}
        else
            echo -e "Hmmm --container-tag is not provided, Trying to extract tag from contrail package url\nBad contrail package url, it should match regex http[s]*://.*/contrail-install-packages_[0-9\.\-]+~[a-zA-Z]+_all.deb"
            exit 1
        fi
    fi

    BUILD_DIR=`mktemp -d`
    make_dockerfile > $BUILD_DIR/Dockerfile

    if [[ -f $CONTRAIL_TEST_ARTIFACT ]]; then
        cp $CONTRAIL_TEST_ARTIFACT $BUILD_DIR/
    fi

    if [[ -f $CONTRAIL_TEST_CI_ARTIFACT ]]; then
        cp $CONTRAIL_TEST_CI_ARTIFACT $BUILD_DIR
    fi

    if [[ -f $CONTRAIL_FAB_ARTIFACT ]]; then
        cp $CONTRAIL_FAB_ARTIFACT $BUILD_DIR
    fi

    # IS docker runnable?
    docker  -v &> /dev/null ; rv=$?

    if [ $rv -ne 0 ]; then
      echo "docker is not installed, please install docker-engine (https://docs.docker.com/engine/installation/)"
      exit 1
    fi

    if [[ -z $CACHE ]]; then
      cache_opt='--no-cache'
    fi

    if [[ $build_type == 'contrail-test' ]]; then
        entrypoint=docker_entrypoint_contrail_test.sh
    elif [[ $build_type == 'contrail-test-ci' ]]; then
        entrypoint=docker_entrypoint_contrail_test_ci.sh
    else
        echo "ERROR! Unknown build_type: $build_type"
        exit 1
    fi

    cp ${BASE_DIR}/docker/${entrypoint} $BUILD_DIR
    if [[ -n $scp_package ]]; then
        # Disabling xtrace to avoid printing SSHPASS
        if xtrace_status; then
            set +x
            xtrace=1
        fi
        ssh_build_arg="--build-arg SSHPASS=$SSHPASS"
    fi
    docker build ${cache_opt} -t ${CONTAINER_TAG} --build-arg ENTRY_POINT=$entrypoint \
        --build-arg CONTRAIL_INSTALL_PACKAGE_URL=$CONTRAIL_INSTALL_PACKAGE_URL \
        ${ssh_build_arg} $BUILD_DIR; rv=$?
    [[ -n $xtrace ]] && set -x

    rm -rf $BUILD_DIR

    if [ $rv -eq 0 ]; then
        echo "Successfully built the container image - $CONTAINER_TAG"
        if [[ -n $EXPORT_PATH ]]; then
            echo "Exporting the image to $EXPORT_PATH"
            mkdir -p $EXPORT_PATH
            docker save $CONTAINER_TAG | gzip -c > ${EXPORT_PATH}/${CONTAINER_TAG/:/-}.tar.gz; rv=$?
            if [ $rv -eq 0 ]; then
                echo "Successfully exported the image to ${EXPORT_PATH}/${CONTAINER_TAG/:/-}.tar.gz"
            fi
        fi
    fi
}

xtrace_status() {
  set | grep -q SHELLOPTS=.*:xtrace
  return $?
}

try_wget () {
    wget -q --spider $1;
    return $?
}

install_req_apt () {
    packages_default="python-pip ant python-dev python-novaclient python-neutronclient python-cinderclient \
                      python-contrail patch python-heatclient python-ceilometerclient python-setuptools \
                      libxslt1-dev libz-dev libyaml-dev git python-glanceclient sshpass"
    packages=${1:-$packages_default}
    DEBIAN_FRONTEND=noninteractive
    apt-get install -y --force-yes $packages
}

install () {
    usage () {
    cat <<EOF
Install Contrail-test or contrail-test-ci

Usage: $0 install [OPTIONS] (contrail-test|contrail-test-ci)

  -h|--help                     Print help message
  --test-repo REPO              Contrail-test git repo, Default: github.com/juniper/contrail-test-ci.git
  --test-ref REF                Contrail-test git reference - commit id, branch, tag, Default: master
  --fab-repo FAB_REPO           Contrail-fabric-utils git repo
  --fab-ref FAB_REF             Contrail-fabric-utils git reference (commit id, branch, or tag), Default: master
  --ci-repo CI_REPO	            Contrail-test-ci git repo, Default: github.com/juniper/contrail-test.git
  --ci-ref CI_REF               Contrail-test-ci reference (commit id, branch, or tag), Default: master
  --test-artifact ARTIFACT      Contrail test tar file - this tar file will be used instead of git source in case provided
  --ci-artifact CI_ARTICACT     Contrail test ci tar file
  --fab-artifact FAB_ARTIFACT   Contrail-fabric-utils tar file
  -u|--package-url PACKAGE_URL  Contrail-install-packages deb package web url (http:// or https://) or scp path
                                (ssh://<server ip/name/< package path>), if url is provided, the
                                package will be installed and setup local repo.
                                In case of scp, user name and password will be read from environment variables
                                SSHUSER - user name to be used during scp
                                SSHPASS - user password to be used during scp

  positional arguments
    What to install             Valid options are contrail-test, contrail-test-ci

 Example:

  $0 install --test-repo https://github.com/hkumarmk/contrail-test --test-ref working
        --ci-repo https://\$GITUSER:\$GITPASS@github.com/juniper/contrail-test-ci -e /tmp/export2
        -u http://nodei16/contrail-install-packages_2.21-105~juno_all.deb contrail-test

  $ export SSHUSER=user1 SSHPASS=password
  $ $0 install --test-repo https://github.com/hkumarmk/contrail-test --test-ref working
     --ci-repo https://\$GITUSER:\$GITPASS@github.com/juniper/contrail-test-ci -e /tmp/export2
     -u ssh://nodei16/var/cache/artifacts/contrail-install-packages_2.21-105~juno_all.deb contrail-test-ci

EOF
    }

    if ! options=$(getopt -o hu: -l help,test-artifact:,ci-artifact:,fab-artifact:,ci-repo:,ci-ref:,test-repo:,test-ref:,contrail-install-package-url:,fab-repo:,fab-ref: -- "$@"); then
# parse error
        usage
        exit 1
    fi
    eval set -- "$options"

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) usage; exit;;
            --test-repo) CONTRAIL_TEST_REPO=$2; shift;;
            --test-ref) CONTRAIL_TEST_REF=$2; shift;;
            -u|--package-url) CONTRAIL_INSTALL_PACKAGE_URL=$2; shift;;
            --fab-repo) CONTRAIL_FAB_REPO=$2; shift;;
            --fab-ref) CONTRAIL_FAB_REF=$2; shift;;
            --ci-repo) CONTRAIL_TEST_CI_REPO=$2; shift;;
            --ci-ref) CONTRAIL_TEST_CI_REF=$2; shift;;
            --test-artifact) CONTRAIL_TEST_ARTIFACT=$2; shift;;
            --ci-artifact) CONTRAIL_TEST_CI_ARTIFACT=$2; shift;;
            --fab-artifact) CONTRAIL_FAB_ARTIFACT=$2; shift;;
            --) :;;
            *) build_type=$1;;
	    esac
	    shift
    done

    install_req_apt

    if [[ -n $CONTRAIL_INSTALL_PACKAGE_URL ]]; then
        if [[ $CONTRAIL_INSTALL_PACKAGE_URL =~ ^http[s]*:// ]]; then
            if try_wget $CONTRAIL_INSTALL_PACKAGE_URL; then
               wget $CONTRAIL_INSTALL_PACKAGE_URL -O /tmp/contrail-install-packages.deb
            else
                echo "ERROR! $CONTRAIL_INSTALL_PACKAGE_URL is not accessible"
                exit 1
            fi
        elif [[ $CONTRAIL_INSTALL_PACKAGE_URL =~ ^ssh:// ]]; then
            if [[ -z $SSHUSER ]]; then
                echo "ERROR! ssh user credentials not given, expected the variables: SSHUSER and SSHPASS" >&2
                exit 1
            fi
            server=` echo $CONTRAIL_INSTALL_PACKAGE_URL | sed 's/ssh:\/\///;s|\/.*||'`
            path=`echo $CONTRAIL_INSTALL_PACKAGE_URL |sed -r 's#ssh://[a-zA-Z0-9_\.\-]+##'`
            sshpass -e scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${SSHUSER}@${server}:${path} /tmp/contrail-install-packages.deb
        else
            echo "ERROR, Unknown url format, only http[s], ssh supported"
            exit 1
        fi

        dpkg -i /tmp/contrail-install-packages.deb
        rm -f /tmp/contrail-install-packages.deb
        cd /opt/contrail/contrail_packages/ && ./setup.sh
    fi

    test_dir='/opt/contrail-test'
    if [[ $build_type == 'contrail-test' ]]; then
        ci_dir='/tmp/contrail-test-ci'
        dir=`dirname $test_dir`
        mkdir -p $dir
        if [[ -f $CONTRAIL_TEST_ARTIFACT ]]; then
            tar -C $dir zxf $CONTRAIL_TEST_ARTIFACT
        else
            git clone $CONTRAIL_TEST_REPO $test_dir
            cd $test_dir
            git checkout $CONTRAIL_TEST_REF;
            git reset --hard;
            rm -fr .git
        fi
    elif [[ $build_type == 'contrail-test-ci' ]]; then
        ci_dir='/opt/contrail-test'
    fi

    dir=`dirname $ci_dir`
    mkdir -p $dir
    if [[ -f $CONTRAIL_TEST_CI_ARTIFACT ]]; then
        tar -C $dir zxf $CONTRAIL_TEST_CI_ARTIFACT
    else
        git clone $CONTRAIL_TEST_CI_REPO $ci_dir;
        cd $ci_dir
        git checkout $CONTRAIL_TEST_CI_REF;
        git reset --hard;
        rm -fr .git
    fi

    mkdir -p /opt/contrail
    if [[ -f $CONTRAIL_FAB_ARTIFACT ]]; then
        cd /opt/contrail
        tar zxf $CONTRAIL_FAB_ARTIFACT
        mv /opt/contrail/fabric-utils /opt/contrail/utils
    else
        git clone $CONTRAIL_FAB_REPO /opt/contrail/utils
        cd /opt/contrail/utils;
        git checkout $CONTRAIL_FAB_REF;
        git reset --hard;
    fi

    if [[ ! $test_dir -ef $ci_dir ]]; then
        cp -RTf $ci_dir $test_dir
    fi
    cd $test_dir
    pip install --upgrade -r requirements.txt
}

## Main starts here

subcommand=$1; shift;
if [[ $subcommand == '-h' || $subcommand == '' ]]; then
    usage
    exit
elif [[ $subcommand == 'docker-build' ]]; then
    docker_build $@
elif [[ $subcommand == 'install' ]]; then
    install $@
else
    echo "Error: '$subcommand' is not a known subcommand." >&2
    echo "       Run '$0 --help' for a list of known subcommands." >&2
    exit 1
fi

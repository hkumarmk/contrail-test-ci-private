#!/bin/bash
#
#TODO: 
# run docker in background
# check if docker finished with error or not
# Print/return the docker id which run this, so it can be provided later as reference for any operations - say should be able to run shell on a failed/successful testrun
# may be a debug option?
# may be more options to pass to run_tests.sh? - this is important
# collect_support_data - this will collect all required details to debug the failures and optionally upload to ftp or something including the failed container? (only collecting data for contrail-test not contrail cluster setup logs) - we may not need to get container as it is reproducable, just need to collect logs, configs, etc.

docker=docker
testbed=/opt/contrail/utils/fabfile/testbeds/testbed.py
feature=sanity
log_path=./log
arg_shell=''
name="contrail_test_$(< /dev/urandom tr -dc a-z | head -c8)"

# ansi colors for formatting heredoc
ESC=$(printf "\e")
GREEN="$ESC[0;32m"
NO_COLOR="$ESC[0;0m"
RED="$ESC[0;31m"

usage () {
  cat <<EOF

Usage: $0 [OPTION] ARG
Run Contrail test suite in docker container

$GREEN  -t, --testbed   $NO_COLOR Path to testbed file in the host, Default: /opt/contrail/utils/fabfile/testbeds/testbed.py
$GREEN  -f, --feature   $NO_COLOR Features or Tags to test - valid options are sanity, quick_sanity,
                    ci_sanity, ci_sanity_WIP, ci_svc_sanity, upgrade, webui_sanity,
                    ci_webui_sanity, devstack_sanity, upgrade_only. Default: sanity
$GREEN  -p, --log-path  $NO_COLOR Directory path on the host, in which contrail-test save the logs
$GREEN  -s, --shell     $NO_COLOR Do not run tests, but leave a shell, this is useful for debugging
$GREEN  -r, --rm	 $NO_COLOR Remove the container on container exit, by default the container will be kept
$GREEN  -b, --background $NO_COLOR run the container in background
$GREEN  -l, --list	  $NO_COLOR List contrail-test containers, by default only list running containers,
		     use with -a to list all containers
$GREEN  -a, --all	  $NO_COLOR affect the operations on ALL available entities
$GREEN  -R, --rebuild   $NO_COLOR Rebuild the contrail test, use with an argument container id
			  Note: rebuilding with container id will create an image with tag img_contrail_test_<random_string>
$GREEN  -n, --no-color       $NO_COLORDisable output coloring 
$GREEN  Arguments:
$GREEN  image tag	  $NO_COLOR Contrail_test docker image tag (e.g juniper/contrail-test-juno:2.21-105)
$GREEN  container id	  $NO_COLOR Container ID - applicable in case of rebuild operation 
EOF
}

red () {
  echo "$RED $@${NO_COLOR}"
}

green () {
  echo "$GREEN $@${NO_COLOR}"
}

nocolor () {
  echo "$NO_COLOR $@"
}

# Provided Docker image available?
is_image_available () {
  $docker images -q ${1:-$pos_arg} | grep -q [[:alnum:]]
}

# Is container available?
is_container_available () {
  docker ps -a -q -f id=$pos_arg | grep -q [[:alnum:]] || docker ps -a -q -f name=$pos_arg | grep -q [[:alnum:]]
}

get_container_name () {
  local name
  name=`$docker ps -a -q -f id=$pos_arg --format "{{.Names}}"`
  if [ `echo $name | grep -c [[:alnum:]]` -ne 0 ]; then
    echo $name
  else
    $docker ps -a -q -f name=$pos_arg --format "{{.Names}}"
  fi
}

clear_colors () {
  RED="";
  GREEN=""
}
## Starts here

for arg in "$@"; do
  shift
  case "$arg" in
    "--help") set -- "$@" "-h" ;;
    "--testbed") set -- "$@" "-t" ;;
    "--feature") set -- "$@" "-f" ;;
    "--log-path") set -- "$@" "-p" ;;
    "--shell") set == "$@" "-s";;
    "--keep") set == "$@" "-k";;
    "--background") set == "$@" "-b";;
    "--no-color") set == "$@" "-n";;
    "list") set == "$@" "-l" ;;
    "all") set == "$@" "-a" ;;
    "rebuild") set == "$@" "-R" ;;
    *) set -- "$@" "$arg"
  esac
done

while getopts "Rrbhf:t:p:sklan" flag; do
  case "$flag" in
    t) testbed=$OPTARG;;
    f) feature=$OPTARG;;
    p) log_path=$OPTARG;;
    s) shell=1;;
    k) keep=1;;
    b) background=1;;
    h) usage; exit;;
    l) list=1;;
    a) all=1;;
    R) rebuild=1;;
    n) clear_colors ;; 
  esac
done

log_path=`readlink -f $log_path`
testbed=`readlink -f $testbed`

# Create log directory if not exist
if [[ ! -d $log_path ]]; then
  mkdir -p $log_path
fi

# IS docker runnable?
$docker  -v &> /dev/null ; rv=$?

if [ $rv -ne 0 ]; then
  red "doker is not installed, please install docker or docker-engine (https://docs.docker.com/engine/installation/)"
  exit 3
fi

# Making args for "all"
if [[ -n $all ]]; then
  arg_list_all=" -a "
fi

# List containers
#TODO: list in better format, list different stuffs like latest containers, failed containers, running containers, finished containers etc
#   able to provide filters
if [[ -n $list ]]; then
    $docker ps $arg_list_all -f name=contrail_test_
    exit 0
fi

## Check positional arguments
pos_arg=${@:$OPTIND:1}

if [[ ! $pos_arg ]]; then
  if [[ $rebuild ]]; then
    red Missing container id/name or image id/name to rebuild
    usage
    exit 101
  else
    red Missing contrail-test docker image tag
    usage
    exit 100
  fi
fi

# Is testbed file exists
if [ ! -f $testbed ]; then
  red "testbed path ($testbed) doesn't exist"
  exit 1
fi


# Volumes to be mounted to container
arg_log_vol=" -v $log_path:/contrail-test/logs "
arg_testbed_json_vol=" -v /root/contrail-test/sanity_testbed.json:/contrail-test/sanity_testbed.json "
arg_sanity_params_vol=" -v /root/contrail-test/sanity_params.ini:/contrail-test/sanity_params.ini "

# Leave shell
if [[ $shell ]]; then
  arg_shell=" -it --entrypoint=/bin/bash "
else
  arg_shell=" --entrypoint=/entrypoint.sh "
fi

# Keep the container 
if [[ $rm ]]; then
  arg_rm=" --rm=true "
else
  arg_rm=" --rm=false "
fi

##
# Rebuild contrail-test
#TODO - add --container-id, --container-name,to specify from where to rebuild, if they are not, use argument
##
if [[ $rebuild ]]; then
  container_name=`get_container_name`
  if [ `echo $container_name | grep -c [[:alnum:]]` -ne 0 ]; then
 # if is_container_available; then
    green "rebuilding container - $pos_arg"
    green "This process will create an image with the container $pos_arg"
    green "Creating the image img_${container_name}"
    $docker commit $pos_arg img_${container_name}
    image_name="img_${container_name}"
  else
    red "Provided container ($pos_arg) is not available"
    exit 6
  fi
else
  image_name=$pos_arg
fi

##
# Docker run
##
if ! is_image_available $image_name; then
    red "Docker image is not available: $pos_arg"
    exit 4
fi
# Run container in background
if [[ -n $background ]]; then
  id=`$docker run $arg_log_vol $arg_testbed_json_vol $arg_sanity_params_vol --name $name -e FEATURE=$feature -d $arg_rm $arg_shell $image_name`
  $docker ps -a --format "ID: {{.ID}}, Name: {{.Names}}" -f id=$id
else
  $docker run $arg_log_vol $arg_testbed_json_vol $arg_sanity_params_vol --name $name -e FEATURE=$feature $arg_bg $arg_rm $arg_shell $image_name
fi



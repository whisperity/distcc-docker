#!/bin/bash
# SPDX-License-Identifier: MIT
#
# main() of the container.
#
# shellcheck disable=SC2317

CRON_RUNNING=0
DISTCC_LOGF="/var/log/distccd.log"
DISTCC_PIDF="/run/distccd.pid"
DISTCC_RUNNING=0
DISTCC_USER="$(cat /var/lib/distcc/distcc.user)"
DISTCC_TAIL_PID=0
HAS_COMPILERS_INSTALLED_FILE="/var/lib/.distcc-compilers-done"
SYSTEM_LOGF="/var/log/syslog"


# Arguments.
JOBS="$(( $(nproc) - 2 ))"
if [ $JOBS -le 0 ]; then
   JOBS=1
fi
NICE=5
STARTUP_TIMEOUT=30
EXEC_CUSTOM=0
CUSTOM_AS_ROOT=0

function usage() {
  cat <<USAGE >&2
Usage:
  <entrypoint> [-j J] [-n N] [--startup-timeout S] [-- command ...]

  -j J | --jobs J             Run distcc server with J worker processes.
                              Default: $JOBS
  -n J | --nice N             Run distcc server with extra N ninceness.
                              Default: $NICE
  --startup-timeout S         Wait S seconds for the server to start.
                              Default: $STARTUP_TIMEOUT

  -- COMMAND ...              Execute COMMAND, e.g., a shell, with the
                              given following arguments after 'distcc'
                              has initialised.
USAGE
}


# "getopt".
while [ $# -gt 0 ]; do
  OPT="$1"
  shift 1

  case "$OPT" in
    --help|-h)
      usage
      exit 0
      ;;
    --jobs|-j)
      JOBS="$1"
      shift 1
      ;;
    --nice|-n)
      NICE="$1"
      shift 1
      ;;
    --startup-timeout)
      STARTUP_TIMEOUT="$1"
      shift 1
      ;;
    --root)
      CUSTOM_AS_ROOT=1
      ;;
    --)
      EXEC_CUSTOM=1
      break
      ;;
    *)
      echo "ERROR: Unexpected argument: '$OPT'" >&2
      exit 2
      ;;
  esac
done


function _syslog() {
  echo -n "$(date +"%b %_d %H:%M:%S") $(hostname) $1" >> "$SYSTEM_LOGF"
  if [ -n "$2" ]; then
    echo -n "[$2]" >> "$SYSTEM_LOGF"
  fi
  echo -n ": " >> "$SYSTEM_LOGF"
  shift 2

  echo "$@" >> "$SYSTEM_LOGF"
  chgrp adm "$SYSTEM_LOGF"
}


function _check_init() {
  # Check init system sanity.

  # shellcheck disable=SC2009
  ps 1 | grep "docker-init" &>/dev/null
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    echo "[!!!] ALERT! This container is expected to be run with" \
      "'docker run --init'!" >&2
    echo "        Init process inside container instead is:" >&2
    ps 1 >&2
    _syslog "_" $$ "! Unknown init daemon: $(ps 1 | tail -n 1)"

    echo >&2
    echo "        We will do our best, but consider this to be" \
      "undefined behaviour!" >&2
  fi
}

function _check_and_install_compilers() {
  # Check that the compilers had been installed into either the image, or at a
  # previous start of the current container. If not, install them.

  # _syslog "_" $$ "Checking for compilers..."
  if [ ! -f "$HAS_COMPILERS_INSTALLED_FILE" ]; then
    _syslog "_" $$ "Failed to find compilers. Installing..."

    /usr/local/sbin/install-compilers.sh
    local RC=$?

    if [ $RC -ne 0 ]; then
      _syslog "_" $$ "! Failed to install compilers after failed detection"
      echo "[!!!] ALERT! This container did not succeed installing compilers!" >&2
      echo "        The DistCC service will not be appropriately usable!" >&2

      return $RC
    fi
  fi

  # _syslog "_" $$ "Compilers are ready."
  return 0
}


# Helper "system" daemons.
function std_cron() {
  start-stop-daemon \
    --pidfile "/run/crond.pid" \
    --exec "$(which cron)" \
    "$@"
  return $?
}

function start_cron() {
  echo "[+++] Starting cron..." >&2
  std_cron --start
  _syslog "cron" "$(cat "/run/crond.pid")" "Cron daemon started."
  CRON_RUNNING=1
  return $?
}

function stop_cron() {
  echo "[---] Stopping cron..." >&2
  _syslog "cron" "$(cat "/run/crond.pid")" "Cron daemon stopping..."
  std_cron --stop
  CRON_RUNNING=0
  return $?
}


# DistCC service daemon.
function std_distccd() {
  start-stop-daemon \
    --pidfile "$DISTCC_PIDF" \
    "$@"
  return $?
}

function start_distccd() {
  # Start the DistCC server normally.
  echo "[+++] Starting distcc..." >&2

  touch "$DISTCC_LOGF" "$DISTCC_PIDF"
  chown "$DISTCC_USER":"$DISTCC_USER" "$DISTCC_LOGF" "$DISTCC_PIDF"
  chmod 0644 "$DISTCC_LOGF" "$DISTCC_PIDF"

  start-stop-daemon --start \
    --exec "$(which distccd)" \
    -- \
      --daemon \
      --user "$DISTCC_USER" \
      --listen "0.0.0.0" \
      --allow "0.0.0.0/0" \
      --port "3632" \
      --jobs "$JOBS" \
      --nice "$NICE" \
      --stats \
      --stats-port "3633" \
      --pid-file "$DISTCC_PIDF" \
      --log-file "$DISTCC_LOGF" \
      --log-level info
  local RC=$?
  if [ $RC -ne 0 ]; then
    return $RC
  fi

  # Wait for DistCC to start properly.
  /usr/local/libexec/wait-for \
    --quiet \
    --timeout="$STARTUP_TIMEOUT" \
    "http://0.0.0.0:3633" \
    -- \
      echo "[^:)] distcc up!" >&2
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "[:'(] distcc failed to start after $STARTUP_TIMEOUT seconds!" >&2
    _syslog "_" $$ "DistCC daemon failed to start!"
    DISTCC_RUNNING=0
  else
    local DISTCC_PID
    DISTCC_PID="$(cat $DISTCC_PIDF)"

    _syslog "distccd" "$DISTCC_PID" "DistCC daemon started."
    _syslog "distccd" "$DISTCC_PID" "DistCC running $JOBS workers..."
    DISTCC_RUNNING=1
  fi
  return $RC
}

function stop_distccd() {
  echo "[---] Stopping distcc..." >&2
  _syslog "distccd" "$(cat $DISTCC_PIDF)" "DistCC daemon stopping..."
  std_distccd --stop \
    --remove-pidfile \
    --user "$DISTCC_USER"
  DISTCC_RUNNING=0
  return $?
}


function atexit() {
  # Pre-exit handler.
  if [ -t 1 ]; then
    stty echoctl
  fi

  if [ "$DISTCC_TAIL_PID" -ne 0 ]; then
    if [ $# -eq 1 ] && [ "$1" -ne 0 ]; then
      SIG=$1
    else
      SIG=9
    fi
    kill -"$SIG" "$DISTCC_TAIL_PID"
    DISTCC_TAIL_PID=0
  fi

  if [ "$DISTCC_RUNNING" -ne 0 ]; then
    stop_distccd
  fi

  if [ "$CRON_RUNNING" -ne 0 ]; then
    stop_cron
  fi
}

function _exit() {
  _syslog "_" $$ "Exit code: $1"
  exit "$1"
}

function sigint() {
  trap - INT

  _syslog "_" $$ "SIGINT."
  echo "[!!!] SIGINT (^C) received! Shutting down..." >&2
  atexit 2

  _exit $((128 + 2))
}

function sighup() {
  trap - HUP

  _syslog "_" $$ "SIGHUP."
  echo "[!!!] SIGHUP received! Shutting down..." >&2
  atexit 1

  _exit $((128 + 1))
}


function custom_command() {
  # Handle dispatch to user's requested command
  echo "[+++] Executing '$1'..." >&2
  echo "[!!!] WARNING: When it terminates, the entire container WILL die!" >&2
  if [ "$CUSTOM_AS_ROOT" -eq 0 ]; then
    _syslog "sudo" "" "$DISTCC_USER : COMMAND=$*"
    su --pty --login "$DISTCC_USER" --command "$@"
  else
    _syslog "sudo" "" "root : COMMAND=$*"
    "$@"
  fi
  local RETURN_CODE=$?
  echo "[---] Custom command '$1' exited with '$RETURN_CODE'" >&2
  return $RETURN_CODE
}


# Entry point.
_syslog "_" $$ "Initialising..."
EXIT_CODE=0
echo "[>>>] DistCC Docker worker container initialising..." >&2
_check_init

_check_and_install_compilers
# shellcheck disable=SC2181
if [ $? -ne 0 ] && [ "$EXEC_CUSTOM" -eq 0 ]; then
  echo "[!!!] Shutting down: container is unusable in its current form!" >&2

  atexit
  _syslog "_" $$ "Shutting down" \
    "(failed to install compilers, unusable container)..."
  _exit $EXIT_CODE
fi

start_cron

start_distccd
if [ "$EXEC_CUSTOM" -eq 1 ]; then
  if [ "$DISTCC_RUNNING" -ne 0 ]; then
    echo "[...] distcc service is running." >&2
  fi

  custom_command "$@"
  EXIT_CODE=$?

  atexit
  _syslog "_" $$ "Shutting down (custom command exited)..."
  _exit $EXIT_CODE
else
  if [ "$DISTCC_RUNNING" -eq 0 ]; then
    atexit
    _syslog "_" $$ "Shutting down (distcc failed to start)..."
    _exit 1
  fi
fi


echo "[...] distcc service is running. SIGINT (^C) terminates." >&2


# Trap for the death of the container in interactive mode. (Unlikely.)
trap sigint INT
trap sighup HUP

if [ -t 1 ]; then
  stty -echoctl
fi


# Just keep the main script alive as long as the DistCC server is alive...
su --pty --login "$DISTCC_USER" --command \
  "tail -f /var/log/distccd.log --pid $(cat "$DISTCC_PIDF")" 2>"/dev/null" & \
DISTCC_TAIL_PID=$!
wait $DISTCC_TAIL_PID


# Do something loud if the process has terminated "organically".
echo "[!!!] distcc service process terminated!" >&2
DISTCC_TAIL_PID=0

sleep 1
atexit 15

_syslog "_" $$ "Shutting down (distcc exited)..."
_exit $((128 + 15))

#!/bin/bash
# SPDX-License-Identifier: MIT
#
# main() of the container.

SYSTEM_LOGF="/var/log/syslog"
DISTCC_LOGF="/var/log/distccd.log"
DISTCC_PIDF="/run/distccd.pid"
DISTCC_USER="$(cat /var/lib/distcc/distcc.user)"
DISTCC_TAIL_PID=0


# Arguments.
JOBS=$(nproc)
NICE=5
STARTUP_TIMEOUT=30
EXEC_CUSTOM=0
CUSTOM_AS_ROOT=0

function usage() {
  echo "Usage:" >&2
  echo "    <entrypoint> [-j J] [-n N] [command ...]" >&2
  echo >&2
  echo "-j J | --jobs J             Run distcc server with J worker processes." >&2
  echo "                            Default: $JOBS" >&2
  echo "-n J | --nice N             Run distcc server with extra N ninceness." >&2
  echo "                            Default: $NICE" >&2
  echo "--startup-timeout S         Wait S seconds for the server to start." >&2
  echo "                            Default: $STARTUP_TIMEOUT" >&2
  echo >&2
  echo "-- COMMAND ...              Execute COMMAND, e.g., a shell, with the " >&2
  echo "                            given following arguments after 'distcc' " >&2
  echo "                            has initialised. " >&2
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
  if [ ! -z "$2" ]; then
    echo -n "[$2]" >> "$SYSTEM_LOGF"
  fi
  echo -n ": " >> "$SYSTEM_LOGF"
  shift 2

  echo "$@" >> "$SYSTEM_LOGF"
  chgrp adm "$SYSTEM_LOGF"
}


function _check_init() {
  # Check init system sanity.
  ps 1 | grep "docker-init" &>/dev/null
  if [ $? -ne 0 ]; then
    echo "[!!!] ALERT! This container is expected to be run with" \
      "'docker run --init'!" >&2
    echo "    Init process inside container instead is:" >&2
    ps 1 >&2
    _syslog "_" $$ "Init is: $(ps 1 | tail -n 1)"

    echo >&2
    echo "    We will do our best, but consider this to be" \
      "undefined behaviour!" >&2
  fi
}


# Helper "system" daemons.
function std_cron() {
  start-stop-daemon \
    --pidfile "/run/crond.pid" \
    --exec "$(which cron)" \
    $@
  return $?
}

function start_cron() {
  echo "[+++] Starting cron..." >&2
  std_cron --start
  _syslog "cron" "$(cat "/run/crond.pid")" "Cron daemon started."
  return $?
}

function stop_cron() {
  echo "[---] Stopping cron..." >&2
  _syslog "cron" "$(cat "/run/crond.pid")" "Cron daemon stopping..."
  std_cron --stop
  return $?
}


# DistCC service daemon.
function std_distccd() {
  start-stop-daemon \
    --pidfile "$DISTCC_PIDF" \
    $@
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
  RC=$?
  if [ $RC -ne 0 ]; then
    return $RC
  fi

  # Wait for DistCC to start properly.
  /usr/bin/wait-for \
    --quiet \
    --timeout="$STARTUP_TIMEOUT" \
    "http://0.0.0.0:3633" \
    -- \
      echo "[^:)] distcc up!" >&2
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "[:'(] distcc failed to start after $STARTUP_TIMEOUT seconds!" >&2
    _syslog "_" $$ "DistCC daemon failed to start!"
  else
    DISTCC_PID="$(cat $DISTCC_PIDF)"
    _syslog "distccd" "$DISTCC_PID" "DistCC daemon started."
    _syslog "distccd" "$DISTCC_PID" "DistCC running $JOBS workers..."
  fi
  return $RC
}

function stop_distccd() {
  echo "[---] Stopping distcc..." >&2
  _syslog "distccd" "$(cat $DISTCC_PIDF)" "DistCC daemon stopping..."
  std_distccd --stop \
    --remove-pidfile \
    --user "$DISTCC_USER"
  return $?
}


function atexit() {
  # Exit handler.
  stty echoctl

  if [ "$DISTCC_TAIL_PID" -ne 0 ]; then
    if [ $# -eq 1 ]; then
      SIG=$1
    else
      SIG=9
    fi
    kill -"$SIG" "$DISTCC_TAIL_PID"
  fi

  stop_distccd
  stop_cron
}

function sigint() {
  trap - INT

  _syslog "_" $$ "SIGINT."
  echo "[!!!] SIGINT (^C) received! Shutting down..." >&2
  atexit 2

  exit $((128 + 2))
}

function sighup() {
  trap - HUP

  _syslog "_" $$ "SIGHUP."
  echo "[!!!] SIGHUP received! Shutting down..." >&2
  atexit 1

  exit $((128 + 1))
}


function custom_command() {
  # Handle dispatch to user's requested command
  echo "[+++] Executing '$1'..." >&2
  echo "[!!!] WARNING: When it terminates, the entire container WILL die!" >&2
  if [ "$CUSTOM_AS_ROOT" -eq 0 ]; then
    _syslog "sudo" "" "$DISTCC_USER : COMMAND=$@"
    su --pty --login "$DISTCC_USER" --command "$@"
  else
    _syslog "sudo" "" "root : COMMAND=$@"
    $@
  fi
  RETURN_CODE=$?
  echo "[---] Custom command '$1' exited with '$RETURN_CODE'" >&2
  return $RETURN_CODE
}


# Entry point.
_syslog "_" $$ "Initialising..."
EXIT_CODE=0
echo "[>>>] DistCC LTS Docker worker container initialising..." >&2
_check_init

start_cron

start_distccd
DISTCC_RUNNING=$?
if [ "$EXEC_CUSTOM" -eq 1 ]; then
  if [ "$DISTCC_RUNNING" -eq 0 ]; then
    echo "[...] distcc service is running." >&2
  fi

  custom_command $@
  EXIT_CODE=$?

  atexit $?
  _syslog "_" $$ "Shutting down..."
  exit $EXIT_CODE
else
  if [ "$DISTCC_RUNNING" -ne 0 ]; then
    stop_cron
    _syslog "_" $$ "Shutting down..."
    exit 1
  fi
fi


echo "[...] distcc service is running. SIGINT (^C) terminates." >&2


# Trap for the death of the container in interactive mode. (Unlikely.)
trap sigint INT
trap sighup HUP

stty -echoctl


# Just keep the main script alive as long as the DistCC server is alive...
su --pty --login "$DISTCC_USER" --command \
  "tail -f /dev/null --pid $(cat "$DISTCC_PIDF")" 2>/dev/null & \
DISTCC_TAIL_PID=$!
wait $DISTCC_TAIL_PID


# Do something loud if the process has terminated "organically".
echo "[!!!] distcc service process terminated!" >&2
DISTCC_TAIL_PID=0

sleep 1
atexit 15

_syslog "_" $$ "Shutting down..."
exit $((128 + 15))

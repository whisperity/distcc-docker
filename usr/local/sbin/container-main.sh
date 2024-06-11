#!/bin/bash
# SPDX-License-Identifier: MIT
#
# main() of the container.
#
# shellcheck disable=SC2317

CRON_PIDF="/run/crond.pid"
CRON_RUNNING=0
DISTCCD_LOGF="/var/log/distccd.log"
DISTCCD_PIDF="/run/distccd.pid"
DISTCCD_PORT=3632
DISTCCD_PORT_STATS=3634
DISTCCD_STATS_HACK_PIDF="/run/distccd-dcc_free_mem.pid"
DISTCCD_STATS_HACK_ACCESS_LOG="/var/log/access.log"
DISTCCD_STATS_HACK_ERROR_LOG="/var/log/error.log"
DISTCCD_STATS_HACK_PORT=3633
DISTCCD_STATS_HACK_RUNNING=0
DISTCCD_RUNNING=0
DISTCCD_TAIL_PID=0
DISTCC_USER="$(cat /var/lib/distcc/distcc.user)"
HAS_COMPILERS_INSTALLED_FILE="/var/lib/distcc-compilers-done"
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
  -n J | --nice N             Run distcc server with extra N niceness.
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
  opt="$1"
  shift 1

  case "$opt" in
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
      echo "ERROR: Unexpected argument: '$opt'" >&2
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
    local -ri rc=$?

    if [ $rc -ne 0 ]; then
      _syslog "_" $$ "! Failed to install compilers after failed detection"
      echo "[!!!] ALERT! This container did not succeed installing" \
        "compilers!" >&2
      echo "        The DistCC service will not be appropriately usable!" >&2

      return $rc
    fi
  fi

  # _syslog "_" $$ "Compilers are ready."
  return 0
}


# Helper "system" daemons.
function std_cron() {
  start-stop-daemon \
    --verbose \
    --exec "$(which cron)" \
    --pidfile "$CRON_PIDF" \
    "$@"
  return $?
}

function start_cron() {
  echo "[+++] Starting cron..." >&2
  std_cron --start
  _syslog "cron" "$(cat "$CRON_PIDF")" "Cron daemon started."
  CRON_RUNNING=1
  return $?
}

function stop_cron() {
  echo "[---] Stopping cron..." >&2
  _syslog "cron" "$(cat "$CRON_PIDF")" "Cron daemon stopping..."
  std_cron --stop
  CRON_RUNNING=0
  return $?
}


# DistCC service daemon.
function std_distccd() {
  start-stop-daemon \
    --verbose \
    --pidfile "$DISTCCD_PIDF" \
    "$@"
  return $?
}

function start_distccd() {
  # Start the DistCC server normally.
  echo "[+++] Starting distccd..." >&2

  touch "$DISTCCD_LOGF" "$DISTCCD_PIDF"
  chown "$DISTCC_USER":"$DISTCC_USER" "$DISTCCD_LOGF" "$DISTCCD_PIDF"
  chmod 0644 "$DISTCCD_LOGF" "$DISTCCD_PIDF"

  start-stop-daemon \
    --verbose \
    --start \
    --exec "$(which distccd)" \
    -- \
      --daemon \
      --user "$DISTCC_USER" \
      --allow "0.0.0.0/0" \
      --listen "0.0.0.0" \
      --log-file "$DISTCCD_LOGF" \
      --log-level info \
      --jobs "$JOBS" \
      --nice "$NICE" \
      --pid-file "$DISTCCD_PIDF" \
      --port "$DISTCCD_PORT" \
      --stats \
      --stats-port "$DISTCCD_PORT_STATS"
  local -i rc=$?
  if [ "$rc" -ne 0 ]; then
    return $rc
  fi

  # Wait for DistCC to start properly.
  /usr/local/libexec/wait-for \
    --quiet \
    --timeout="$STARTUP_TIMEOUT" \
    "http://0.0.0.0:$DISTCCD_PORT_STATS" \
    -- \
      echo "[^:)] distccd up!" >&2
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[:'(] distccd failed to start after $STARTUP_TIMEOUT seconds!" >&2
    _syslog "_" $$ "DistCC daemon failed to start!"
    DISTCCD_RUNNING=0
  else
    local -i distccd_pid
    distccd_pid="$(cat $DISTCCD_PIDF)"

    _syslog "distccd" "$distccd_pid" "DistCC daemon started."
    _syslog "distccd" "$distccd_pid" "DistCC running $JOBS workers..."
    DISTCCD_RUNNING=1
  fi
  return $rc
}

function stop_distccd() {
  echo "[---] Stopping distccd..." >&2
  _syslog "distccd" "$(cat "$DISTCCD_PIDF")" "DistCC daemon stopping..."
  std_distccd \
    --stop \
    --remove-pidfile \
    --user "$DISTCC_USER"
  DISTCCD_RUNNING=0
  return $?
}


# DistCC --stats "dcc_free_mem" hack response transformer daemon.
function std_distccd_dcc_free_mem() {
  start-stop-daemon \
    --verbose \
    --pidfile "$DISTCCD_STATS_HACK_PIDF" \
    "$@"
  return $?
}

function start_distccd_free_mem_server() {
  # Start the DistCC server free memory reporting transformer.
  echo "[+++] Starting distccd dcc_free_mem ..." >&2

  touch "$DISTCCD_STATS_HACK_ACCESS_LOG" "$DISTCCD_STATS_HACK_ERROR_LOG" \
    "$DISTCCD_STATS_HACK_PIDF"
  chown "$DISTCC_USER":"$DISTCC_USER" \
    "$DISTCCD_STATS_HACK_ACCESS_LOG" "$DISTCCD_STATS_HACK_ERROR_LOG" \
    "$DISTCCD_STATS_HACK_PIDF"
  chmod 0644 \
    "$DISTCCD_STATS_HACK_ACCESS_LOG" "$DISTCCD_STATS_HACK_ERROR_LOG" \
    "$DISTCCD_STATS_HACK_PIDF"

  std_distccd_dcc_free_mem \
    --start \
    --background \
    --chuid "$DISTCC_USER" \
    --exec "$(which python3)" \
    --make-pidfile \
    -- \
      "/usr/local/share/dcc_free_mem/stat_server.py" \
        --access-log "$DISTCCD_STATS_HACK_ACCESS_LOG" \
        --error-log "$DISTCCD_STATS_HACK_ERROR_LOG" \
        --system-log "$SYSTEM_LOGF" \
        "$DISTCCD_STATS_HACK_PORT" \
        "$DISTCCD_PORT_STATS"
  local -i rc=$?
  if [ "$rc" -ne 0 ]; then
    return $rc
  fi

  # Wait for DistCC to start properly.
  /usr/local/libexec/wait-for \
    --quiet \
    --timeout="$STARTUP_TIMEOUT" \
    "http://0.0.0.0:$DISTCCD_STATS_HACK_PORT" \
    -- \
      echo "[^:)] distccd dcc_free_mem up!" >&2
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[:'(] distccd dcc_free_mem failed to start after" \
      "$STARTUP_TIMEOUT seconds!" >&2
    _syslog "_" $$ "DistCC dcc_free_mem failed to start!"
    DISTCCD_STATS_HACK_RUNNING=0
  else
    local distccd_free_mem_pid
    distccd_free_mem_pid="$(cat "$DISTCCD_STATS_HACK_PIDF")"

    _syslog "distccd-dcc_free_mem" "$distccd_free_mem_pid" \
      "DistCC dcc_free_mem started."
    DISTCCD_STATS_HACK_RUNNING=1
  fi
  return $rc
}

function stop_distccd_dcc_free_mem() {
  echo "[---] Stopping distccd dcc_free_mem ..." >&2
  _syslog "distccd-dcc_free_mem" "$(cat "$DISTCCD_STATS_HACK_PIDF")" \
    "DistCC dcc_free_mem stopping..."
  std_distccd_dcc_free_mem \
    --stop \
    --remove-pidfile \
    --user "$DISTCC_USER"
  DISTCCD_STATS_HACK_RUNNING=0
  return $?
}


function atexit() {
  # Pre-exit handler.
  if [ -t 1 ]; then
    stty echoctl
  fi

  local -i sig
  if [ "$DISTCCD_TAIL_PID" -ne 0 ]; then
    if [ $# -eq 1 ] && [ "$1" -ne 0 ]; then
      sig=$1
    else
      sig=9
    fi
    kill -"$sig" "$DISTCCD_TAIL_PID"
    DISTCCD_TAIL_PID=0
  fi

  if [ "$DISTCCD_STATS_HACK_RUNNING" -ne 0 ]; then
    stop_distccd_dcc_free_mem
  fi

  if [ "$DISTCCD_RUNNING" -ne 0 ]; then
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
  local -ri rc=$?
  echo "[---] Custom command '$1' exited with '$rc'" >&2
  return $rc
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
start_distccd_free_mem_server
if [ "$EXEC_CUSTOM" -eq 1 ]; then
  if [ "$DISTCCD_RUNNING" -ne 0 ]; then
    echo "[...] distccd service is running." >&2
  fi
  if [ "$DISTCCD_STATS_HACK_RUNNING" -ne 0 ]; then
    echo "[...] distccd dcc_free_mem is running." >&2
  fi

  custom_command "$@"
  EXIT_CODE=$?

  atexit
  _syslog "_" $$ "Shutting down (custom command exited)..."
  _exit $EXIT_CODE
else
  if [ "$DISTCCD_RUNNING" -eq 0 ] \
      || [ "$DISTCCD_STATS_HACK_RUNNING" -eq 0 ]; then
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
  "tail -f /var/log/distccd.log --pid $(cat "$DISTCCD_PIDF")" 2>"/dev/null" & \
DISTCCD_TAIL_PID=$!
wait $DISTCCD_TAIL_PID


# Do something loud if the process has terminated "organically".
echo "[!!!] distcc service process terminated!" >&2
DISTCCD_TAIL_PID=0

sleep 1
atexit 15

_syslog "_" $$ "Shutting down (distcc exited)..."
_exit $((128 + 15))

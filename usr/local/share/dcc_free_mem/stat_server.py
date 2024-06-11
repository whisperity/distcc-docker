#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Implements a transformating wrapper over the requests otherwise served by
``distccd(1)``'s ``--stats`` server, otherwise known as a "man-in-the-middle"
(MITM) access.
This Python script injects the ``dcc_free_mem`` statistical variable into the
output, with which clients can obtain the currently available system memory
that could be consumeable by spawned compiler jobs, as returned by ``free(1)``.
"""


# Visually, the script can be summarised with the following communication
# diagram:
#
#                                    DistCC Docker Container
#                   ┌───────────────────────────────────────────────────────┐
#                   │   ┌───────────────────┐                               │
# ┌────┐ :3633 GET  │   │   Python server   │  :3634 GET  ┌───────────────┐ │
# │HTTP├────────────┼───►    port :3633     ├─────────────► distccd stats │ │
# └────┘            │   └───────▲─┬─────▲───┘             │   port :3634  │ │
#                   │           │ │     │                 └───────┬───────┘ │
# ┌────┐ :3634 GET  │           │ │     │   HTTP socket response  │         │
# │HTTP├────────────┼──►X       │ │     └─────────────────────────┘         │
# └────┘            │           │ │                                         │
#                   │           │ │ subprocess I/O                          │
#                   │           │ │                                         │
#                   │   ┌───────┴─▼────────┐                                │
#                   │   │ coreutils 'free' │                                │
#                   │   └──────────────────┘                                │
#                   └───────────────────────────────────────────────────────┘
#


import argparse
import datetime
import http
import http.server
import os
import socket
import subprocess
import sys
import urllib.request
from typing import List, Optional, Union, cast


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="""
Serve `dcc_free_mem` alongside the reported statistics of a 'distccd' server.
""",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument("listen_port",
                        metavar="listen_port",
                        type=int,
                        help="""
The TCP port to listen on where the extended statistics will be reported.
"""
                        )

    parser.add_argument("stats_port",
                        metavar="PORT",
                        type=int,
                        default=3633,
                        help="""
The statistics server's port number, as was passed to "distccd
--stats-port=PORT".
"""
                        )

    parser.add_argument("--access-log",
                        type=str,
                        default="/var/log/access.log",
                        help="""
Path to the webserver's output "access log" file.
""")

    parser.add_argument("--error-log",
                        type=str,
                        default="/var/log/error.log",
                        help="""
Path to the webserver's output "error log" file.
""")

    parser.add_argument("--system-log",
                        type=str,
                        default="/var/log/syslog",
                        help="""
Path to the standard "syslog" file.
""")

    return parser


def _syslog(file: str, message: str, facility: str, pid: Optional[int] = None):
    """
    Logs one line to the "emulated" system log.
    """
    date = datetime.datetime.now().strftime("%b %_d %H:%M:%S")
    hostname = socket.gethostname()
    if not pid:
        pid = os.getpid()
    pid_str = f"[{pid}]".format(pid)
    log_line = f"{date} {hostname} {facility}{pid_str}: {message}"

    try:
        with open(file, 'a') as io:
            io.writelines([log_line])
    except Exception:
        print(log_line, file=sys.stderr)


class DistCCStatsMITMRequestHandler(http.server.BaseHTTPRequestHandler):
    def log_request(self,
                    code: Union[int, str] = '-',
                    size: Union[int, str] = '-'):
        if isinstance(code, http.HTTPStatus):
            code = code.value
        self.log_access('"%s" %s %s', self.requestline, str(code), str(size))

    def log_access(self, format: str, *args, **kwargs):
        log = cast(DistCCStatsMITMHTTPServer, self.server).access_log
        return self.log(format, log, *args, **kwargs)

    def log_message(self, format: str, *args):
        log = cast(DistCCStatsMITMHTTPServer, self.server).error_log
        return self.log(format, log, *args)

    def log(self, format: str, file: str, *args):
        log_line = "%s - - [%s] %s\n" % \
            (self.address_string(), self.log_date_time_string(), format % args)

        try:
            with open(file, 'a') as io:
                io.writelines([log_line])
        except Exception:
            log = cast(DistCCStatsMITMHTTPServer, self.server).system_log
            _syslog(log,
                    f"{self.__class__.__name__} failed to log a message "
                    f"to file \"{file}\":",
                    "stat_server.py")
            _syslog(log,
                    log_line.rstrip(),
                    "stat_server.py")
            print(log_line, file=sys.stderr)

    def do_GET(self):
        stats_port = cast(DistCCStatsMITMHTTPServer, self.server).stats_port

        try:
            with urllib.request.urlopen(f"http://0.0.0.0:{stats_port}") \
                    as distccd_response_obj:
                distccd_response = distccd_response_obj.read().decode()
                code = distccd_response_obj.code
                headers = distccd_response_obj.headers
        except Exception:
            import traceback
            return self.send_error(http.HTTPStatus.INTERNAL_SERVER_ERROR,
                                   "An exception occurred when querying the "
                                   f"--stats server at :{stats_port}",
                                   traceback.format_exc())

        def _mimic_response_headers(size: Union[str, int] = '-',
                                    override_code: Optional[int] = None):
            code_ = code
            if override_code:
                if isinstance(override_code, http.HTTPStatus):
                    override_code = override_code.value
                code_ = override_code

            self.log_request(code_, size)
            self.send_response_only(code_)
            for header, value in headers.items():
                self.send_header(header, value)
            self.end_headers()

        def _send_response(response: bytes,
                           override_code: Optional[int] = None):
            _mimic_response_headers(len(response), override_code)
            self.wfile.write(response)

        if not distccd_response \
                or "<distccstats>" not in distccd_response \
                or "</distccstats>" not in distccd_response:
            self.log_error(
                "%s",
                f"--stats at :{stats_port} returned empty or invalid response")

            return _send_response(b'', http.HTTPStatus.NO_CONTENT)

        if "dcc_free_mem" in distccd_response:
            _server = cast(DistCCStatsMITMHTTPServer, self.server)
            if not _server.has_warned_about_being_unnecessary:
                _server.has_warned_about_being_unnecessary = True
                _syslog(_server.system_log,
                        "'dcc_free_mem' found in the output of native "
                        "'distccd', the wrapper is now unnecessary!",
                        "stat_server.py")
                self.log_error("%s", "'stat_server.py' is unnecessary!")

            return _send_response(distccd_response.encode())

        dcc_free_mem: Optional[int] = None
        try:
            free_result = subprocess. \
                check_output(["free", "--mebi", "--wide"]). \
                decode().splitlines()
            for line in free_result:
                if line.startswith("Mem:"):
                    values = list(filter(bool, line.split(' ')))
                    dcc_free_mem = int(values[-1])

            if dcc_free_mem is None:
                raise ValueError(
                    "No 'Mem:' line found in the output of `free`")
        except Exception:
            import traceback
            traceback.print_exc()
            self.log_error("%s", "Failed to get valid response from `free`!")

            return _send_response(
                distccd_response.encode(),
                http.HTTPStatus.NON_AUTHORITATIVE_INFORMATION)

        response_lines: List[str] = distccd_response.splitlines()
        response_lines.insert(-1, "dcc_free_mem %d MB" % dcc_free_mem)
        response_lines.append('')

        return _send_response('\n'.join(response_lines).encode())


class DistCCStatsMITMHTTPServer(http.server.HTTPServer):
    def __init__(self, server_address, bind_and_activate, stats_port: int,
                 access_log: str, error_log: str, system_log: str):
        super().__init__(server_address,
                         DistCCStatsMITMRequestHandler,
                         bind_and_activate)
        self.stats_port = stats_port
        self.access_log = access_log
        self.error_log = error_log
        self.system_log = system_log
        self.has_warned_about_being_unnecessary = False


def main(args: argparse.Namespace) -> int:
    server = DistCCStatsMITMHTTPServer(
        server_address=("0.0.0.0", args.listen_port),
        bind_and_activate=True,
        stats_port=args.stats_port,
        access_log=args.access_log,
        error_log=args.error_log,
        system_log=args.system_log
    )

    server.serve_forever()

    return 0


if __name__ == "__main__":
    opts = argument_parser()
    args = opts.parse_args()
    sys.exit(main(args) or 0)

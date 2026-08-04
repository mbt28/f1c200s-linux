#!/usr/bin/env python3
"""Run commands on the F1C200s console over /dev/ttyUSB0 (CH341, 115200).

CRITICAL: DTR/RTS must be deasserted BEFORE the port is opened -- on this
CH341 wiring asserting either line resets the board (a live session was lost
to it once). pyserial stores the values set before open() and applies them
as the port comes up, so never let the defaults (True) through.
"""
import os
import sys
import time

import serial

PORT = os.environ.get("SERPORT", "/dev/ttyUSB0")
BAUD = 115200


def open_port():
    s = serial.Serial()
    s.port = PORT
    s.baudrate = BAUD
    s.timeout = 0.2
    s.dtr = False          # before open -- see module docstring
    s.rts = False
    s.open()
    s.dtr = False          # and again, belt and braces
    s.rts = False
    return s


def read_until_quiet(s, timeout=25.0, quiet=1.5):
    """Read until the line goes quiet for `quiet` s, or `timeout` elapses."""
    buf = b""
    start = last = time.time()
    while time.time() - start < timeout:
        chunk = s.read(4096)
        if chunk:
            buf += chunk
            last = time.time()
        elif time.time() - last > quiet:
            break
    return buf.decode("utf-8", "replace")


def main():
    timeout = float(os.environ.get("SERTIMEOUT", "25"))
    quiet = float(os.environ.get("SERQUIET", "1.5"))
    s = open_port()

    # Drain whatever the console has queued, then poke for a prompt.
    seen = read_until_quiet(s, timeout=6, quiet=1.0)
    s.write(b"\n")
    s.flush()
    seen += read_until_quiet(s, timeout=6, quiet=1.0)
    if "login:" in seen:
        s.write(b"root\n")
        s.flush()
        seen += read_until_quiet(s, timeout=10, quiet=1.0)

    for cmd in sys.argv[1:]:
        s.write((cmd + "\n").encode())
        s.flush()
        print("======== %s" % cmd, flush=True)
        print(read_until_quiet(s, timeout=timeout, quiet=quiet), flush=True)
    s.close()


main()

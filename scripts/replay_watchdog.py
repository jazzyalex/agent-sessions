"""Kill only this watchdog's parent if the replay fails to close its input in time.

Run as a child of the opt-in XCTest host with a private stdin pipe. Closing that
pipe disarms the watchdog. No session data or process arguments are printed.
"""
import argparse
import os
import select
import signal
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=180)
    seconds = parser.parse_args().seconds
    if not 0 < seconds <= 180:
        return 2
    parent = os.getppid()
    ready, _, _ = select.select([sys.stdin], [], [], seconds)
    if not ready and parent > 1 and os.getppid() == parent:
        os.kill(parent, signal.SIGKILL)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

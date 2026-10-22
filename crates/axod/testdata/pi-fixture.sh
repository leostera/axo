#!/bin/sh
# Stand-in for daemon catalog/PTY tests only. Preserve the inherited writer lock
# without loading account Pi configuration, credentials, or extension code.
exec /bin/sleep 60

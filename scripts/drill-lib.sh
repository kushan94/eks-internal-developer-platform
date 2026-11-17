#!/usr/bin/env bash
# Shared by the restore drills (rds-restore-drill.sh and cnpg-restore-drill.sh).

# The marker a drill wrote is the line of psql's output that looks like a timestamp.
# psql prints a command tag ("CREATE TABLE", "INSERT 0 1") for every statement, and
# newer versions print the result of every statement in a multi-statement command, so
# neither the first nor the last line is the marker. Both drills once took the wrong one:
# the RDS drill waited forever for a restore point after "INSERT 0 1".
marker_line() { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -n 1; }

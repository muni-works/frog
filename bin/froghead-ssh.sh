#!/bin/bash
# froghead-ssh.sh — run a command on the frog head node (Jetson Orin, 192.168.2.21).
# Usage: T=<seconds> bin/froghead-ssh.sh '<command>'   (T is the command timeout, default 60)
# Password auth (frog). Replaces ad-hoc /private/tmp helpers so approval cards
# reference a known, committed script instead of an anonymous temp file.
exec timeout ${T:-60} sshpass -p frog ssh \
  -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  frog@192.168.2.21 "$@"

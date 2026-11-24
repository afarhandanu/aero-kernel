#!/bin/bash

# KernelSU / ZephyrSU
# SUSFS_ENABLED=false keeps the old main-branch (kprobes) flow.
if [ "$KERNELSU" = true ]; then
  if [ "$SUSFS_ENABLED" = false ]; then
    chmod +x scripts/goodies/kernelsu.sh
    source scripts/goodies/kernelsu.sh
  else
    chmod +x scripts/goodies/kernelsu-builtin.sh
    source scripts/goodies/kernelsu-builtin.sh
  fi
fi

# Baseband Guard
if [ "$BBG" = true ]; then
  chmod +x scripts/goodies/baseband.sh
  source scripts/goodies/baseband.sh
fi

# NoMount
if [ "$NOMOUNT" = true ]; then
  chmod +x scripts/goodies/nomount.sh
  source scripts/goodies/nomount.sh
fi

# Droidspaces
if [ "$DROIDSPACES" = true ]; then
  chmod +x scripts/goodies/droidspaces.sh
  source scripts/goodies/droidspaces.sh
fi

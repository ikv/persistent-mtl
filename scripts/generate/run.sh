#!/usr/bin/env bash

cd "$(dirname "${BASH_SOURCE[0]}")"
exec stack GeneratePersistentAPI.hs

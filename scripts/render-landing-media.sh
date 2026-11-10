#!/bin/sh
# Renders the landing page's film and hero loop into site/shots from the real overlay views
# (see app/Sources/Subline/LandingMedia/LandingMediaMode.swift).
#
#   scripts/render-landing-media.sh               # film + loop (MP4, WebM, JPEG poster each)
#   scripts/render-landing-media.sh film          # only the film
#   scripts/render-landing-media.sh preview DIR   # contact-sheet stills into DIR (default build/landing-preview)
#
# Needs ffmpeg (brew install ffmpeg). Runs offscreen with a throwaway home folder and an empty
# working directory, so it never reads or writes your own Subline settings.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
(cd app && swift build --product Subline)
bin="$root/app/.build/debug/Subline"
out="$root/site/shots"
case "${1:-}" in
  preview|probe)
    mode=$1
    out="${2:-$root/build/landing-preview}"
    set -- "$mode" ;;
esac
mkdir -p "$out"
home=$(mktemp -d "${TMPDIR:-/tmp}/subline-landing.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp}/subline-landing-cwd.XXXXXX")
trap 'rm -rf "$home" "$work"' EXIT
cd "$work"
CFFIXED_USER_HOME="$home" HOME="$home" LANDING_ICON="$root/docs/assets/icon.png" "$bin" landing-media "$out" "$@"

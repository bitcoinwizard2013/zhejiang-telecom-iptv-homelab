#!/bin/sh
# Read-only helper. Does not load configuration files or print network addresses.
set -u
usage() { printf '%s\n' 'Usage: sh doctor.sh [--playlist http(s)://YOUR_GATEWAY/playlist.m3u]'; }
playlist=''
case "$#" in
  0) ;;
  1) case "$1" in --help|-h) usage; exit 0;; *) usage >&2; exit 2;; esac ;;
  2) [ "$1" = '--playlist' ] || { usage >&2; exit 2; }; playlist=$2 ;;
  *) usage >&2; exit 2 ;;
esac
if [ -n "$playlist" ]; then
  case "$playlist" in http://*|https://*) ;; *) printf '%s\n' 'ERROR: HTTP(S) playlist URL required.' >&2; exit 2;; esac
  case "$playlist" in *'@'*|*'?'*|*'#'*) printf '%s\n' 'ERROR: Credentials, query strings and fragments are not accepted.' >&2; exit 2;; esac
fi
printf '%s\n' 'IPTV read-only check (no addresses or authentication values printed)'
for tool in ip curl awk mktemp; do
  if command -v "$tool" >/dev/null 2>&1; then printf '%s: available\n' "$tool"; else printf '%s: missing\n' "$tool"; fi
done
if command -v ip >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
  interfaces=$(ip -o link show 2>/dev/null | awk 'END { print NR+0 }')
  defaults=$(ip -4 route show default 2>/dev/null | awk 'END { print NR+0 }')
  printf 'Interface rows: %s; IPv4 default route rows: %s\n' "$interfaces" "$defaults"
  printf '%s\n' 'Counts do not prove the correct upstream path. Inspect routes locally.'
fi
[ -n "$playlist" ] || exit 0
for tool in curl awk mktemp; do command -v "$tool" >/dev/null 2>&1 || { printf '%s\n' 'ERROR: Playlist check dependencies missing.' >&2; exit 3; }; done
umask 077
tmp=$(mktemp "${TMPDIR:-/tmp}/iptv-doctor.XXXXXX") || exit 3
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Never follow redirects or log the URL/body. Limit time and the on-disk body size.
if ! (ulimit -f 1024 2>/dev/null || exit 1; curl --fail --silent --max-time 8 --max-filesize 524288 --proto '=http,https' --output "$tmp" -- "$playlist") 2>/dev/null; then
  printf '%s\n' 'ERROR: Playlist request failed or exceeded limits. No response content shown.' >&2; exit 4
fi
if ! awk 'NR==1 { sub(/\r$/, ""); if ($0 !~ /^#EXTM3U([[:space:]]|$)/) exit 1 } END { if (NR==0) exit 1 }' "$tmp"; then
  printf '%s\n' 'ERROR: Response is not an M3U playlist.' >&2; exit 5
fi
count=$(awk '/^#EXTINF:/ { n++ } END { print n+0 }' "$tmp")
printf 'M3U header: valid; channel metadata rows: %s\n' "$count"
[ "$count" -gt 0 ] || { printf '%s\n' 'WARNING: No channel metadata found.' >&2; exit 6; }
printf '%s\n' 'This checks the playlist only; video playback has not been tested.'

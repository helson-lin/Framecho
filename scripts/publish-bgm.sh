#!/bin/bash
# Prepares the background music library from a folder of source files.
#
#   scripts/publish-bgm.sh <source-folder> --cache     copy into this Mac's
#       music cache, so Studio uses the tracks without downloading them
#   scripts/publish-bgm.sh <source-folder> --publish   upload them as assets
#       of the bgm-v1 release that BackgroundMusicCatalog.baseURL points at
#
# Each source file is renamed to the catalog's file name. Confirm every
# track's license allows redistribution before publishing.
set -euo pipefail

if [[ $# -ne 2 || ( "$2" != "--cache" && "$2" != "--publish" ) ]]; then
  echo "usage: $0 <source-folder> --cache|--publish" >&2
  exit 1
fi
source_dir="$1"
mode="$2"
repo="helson-lin/Framecho"
tag="bgm-v1"

# Source file -> catalog file name (Framecho/BackgroundMusic.swift).
mapping=(
  "freepd.com_River Meditation.mp3|river-meditation.mp3"
  "Just-Relax-No-Copyright-Music-01-Just-Relax.mp3|just-relax.mp3"
  "Peaceful-Sleep-Music-Free-Royalty-Free-Music-by-Liborio-Conti-01-Peaceful-Sleep-Music.mp3|peaceful-sleep-music.mp3"
  "SerenityInTheWoods.mp3|serenity-in-the-woods.mp3"
  "Cinelax.mp3|cinelax.mp3"
  "Emotional-Piano-Free-Royalty-Free-Relaxing-Music-by-Liborio-Conti-01-I-Believe.mp3|i-believe.mp3"
  "DeeperMeaning.mp3|deeper-meaning.mp3"
  "Horizon.mp3|horizon.mp3"
  "Wonder.mp3|wonder.mp3"
  "Light-And-Balanced-No-Copyright-Music-01-Light-And-Balanced.mp3|light-and-balanced.mp3"
  "freepd.com_Advertime.mp3|advertime.mp3"
  "four_loop.mp3|four-loop.mp3"
  "once_upon_a_time_loop.mp3|once-upon-a-time.mp3"
  "Village Tarantella.mp3|village-tarantella.mp3"
  "freepd.com_3 am West End.mp3|3-am-west-end.mp3"
  "freepd.com_Flutey Jazz.mp3|flutey-jazz.mp3"
  "freepd.com_A Good Bass for Gambling.mp3|a-good-bass-for-gambling.mp3"
)

if [[ "$mode" == "--cache" ]]; then
  destination="$HOME/Library/Application Support/Framecho/Music"
else
  destination="$(mktemp -d)/bgm"
fi
mkdir -p "$destination"

for entry in "${mapping[@]}"; do
  source_name="${entry%%|*}"
  file_name="${entry##*|}"
  if [[ ! -f "$source_dir/$source_name" ]]; then
    echo "error: missing $source_dir/$source_name" >&2
    exit 1
  fi
  cp "$source_dir/$source_name" "$destination/$file_name"
done

if [[ "$mode" == "--cache" ]]; then
  echo "Copied ${#mapping[@]} tracks into $destination"
  exit 0
fi

if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release create "$tag" --repo "$repo" --title "Background music library" \
    --notes "Tracks for Studio's background music library. Not an app release." --latest=false
fi
gh release upload "$tag" --repo "$repo" --clobber "$destination"/*.mp3
echo "Uploaded ${#mapping[@]} tracks to $repo release $tag"

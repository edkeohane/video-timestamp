#!/bin/bash
# ==============================================================================
# Batch Video Watermark and Timestamp Processor (macOS / BSD)
#
# Scans for MP4 input files, extracts the container creation timestamp (recording
# end time), derives the start time by subtracting the total frame count, overlays
# a running millisecond-accurate timestamp watermark, adjusts playback timing,
# and prepends "done_" to processed source files.
# ==============================================================================

# Check for Safari/macOS in-progress download packages and alert if present
INCOMPLETE=$(find . -type d -name "*input*.download" -o -path "*.download/*input*.mp4" 2>/dev/null | head -n 1)
if [ -n "$INCOMPLETE" ]; then
  echo "Notice: Incomplete .download bundles detected. Skipping until downloads complete."
fi

# Track whether any eligible files were found
FOUND=0

# Use process substitution (< <(...)) instead of piping find into while.
# This prevents running the loop in a subshell, preserving variable state.
while IFS= read -r -d $'\0' file; do
  FOUND=1
  echo "Processing: $file"

  # ----------------------------------------------------------------------------
  # 1. Extract Creation Time
  # Read the QuickTime/MP4 container creation timestamp via ffprobe.
  # Note: In standard recording pipelines, this tag marks the file closing (end) time.
  # ----------------------------------------------------------------------------
  CREATION_TIME_RAW=$(ffprobe -v error \
    -show_entries format_tags=creation_time \
    -of default=noprint_wrappers=1:nokey=1 "$file")

  if [ -z "$CREATION_TIME_RAW" ]; then
    echo "Error: No creation_time tag found in $file. Skipping."
    continue
  fi

  echo "Creation time (end): $CREATION_TIME_RAW"

  # ----------------------------------------------------------------------------
  # 2. Convert Timestamp to Unix Epoch
  # Strip ISO-8601 'T' delimiter and fractional seconds, then parse via macOS date.
  # '-j' disables system clock modification; '-u' enforces UTC evaluation.
  # ----------------------------------------------------------------------------
  CREATION_TIME_CLEAN=$(echo "$CREATION_TIME_RAW" | sed 's/T/ /; s/\..*//')
  CREATION_EPOCH=$(date -j -u -f "\%Y-\%m-\%d \%H:\%M:\%S" "$CREATION_TIME_CLEAN" "+%s")

  # ----------------------------------------------------------------------------
  # 3. Read Packet / Frame Count
  # Read total packet count from the primary video stream and remove formatting commas.
  # ----------------------------------------------------------------------------
  FRAME_COUNT=$(ffprobe -v error -select_streams v:0 \
    -count_packets -show_entries stream=nb_read_packets \
    -of csv=p=0 "$file" | tr -d ',')

  echo "Frame count: $FRAME_COUNT"

  # ----------------------------------------------------------------------------
  # 4. Derive File Start Time
  # Subtract total elapsed frames (seconds) from the end epoch to find recording start.
  # ----------------------------------------------------------------------------
  START=$((CREATION_EPOCH - FRAME_COUNT))
  START_HUMAN=$(date -r "$START" "+%Y-%m-%d %H:%M:%S")
  echo "Derived start time: $START_HUMAN"

  # ----------------------------------------------------------------------------
  # 5. Build Output File Path
  # Preserve the source directory and format the target as 28VL-DDMMYYYY-HHMMSS.mp4.
  # ----------------------------------------------------------------------------
  DIR=$(dirname "$file")
  BASE=$(basename "$file")
  START_DATE=$(date -r "$START" "+%d%m%Y")
  START_TIME=$(date -r "$START" "+%H%M%S")
  OUTPUT="${DIR}/28VL-${START_DATE}-${START_TIME}.mp4"
  echo "Output file: $OUTPUT"

  # ----------------------------------------------------------------------------
  # 6. Encode Video and Overlay Timestamp
  # -nostdin: Prevents ffmpeg from consuming stdin meant for the while read loop.
  #
  # Filter Chain (Order is critical):
  # 1. drawtext: Generates clock display from the computed epoch ($START).
  #    Calculates milliseconds using frame index modulus: (n % 30) * 1000 / 30.
  # 2. setpts: Scales timestamps (30.0*PTS) AFTER drawtext so the clock does not
  #    advance 30x faster than real time.
  #
  # Encoding flags:
  # -c:v libx264: H.264 video codec
  # -b:v 1M: Target video bitrate of 1 Mbps
  # -preset superfast: Faster encoding profile
  # -r 1: Set output frame rate to 1 fps
  # ----------------------------------------------------------------------------
  if ffmpeg -nostdin -i "$file" -vf \
    "drawtext=fontfile='/System/Library/Fonts/Supplemental/Arial.

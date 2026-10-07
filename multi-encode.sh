#!/bin/bash
#
# Batch-processes timelapse videos in the current directory.
#
# For each "*input*.mp4" file, the script:
#   1. Reads the file's creation_time metadata (the moment recording ENDED).
#   2. Counts the video frames, which is assumed to equal the recording
#      duration in seconds (i.e. one frame was captured per real second).
#   3. Works out the real START time by subtracting that duration from the end time.
#   4. Re-encodes the video with a running clock overlay that starts at that
#      start time, and names the output file after the start date/time.
#   5. Renames the original to "complete_<name>" so it is not processed twice.
#
# NOTE: Uses macOS/BSD `date` flags (-j, -f, -r). These will not work with GNU
# date on Linux without modification.

# Make globs that match nothing expand to an empty list (instead of the
# literal pattern), so the loop below simply doesn't run when no files match.
shopt -s nullglob

# ---------------------------------------------------------------------------
# Build the list of files to process
# ---------------------------------------------------------------------------
FILES=()
for f in *input*.mp4; do
  [[ -f "$f" ]] || continue                    # real files only (skip directories, broken links)
  [[ "$f" == complete_* ]] && continue         # already processed on a previous run
  [[ "$f" == *.download* ]] && continue        # pending downloads (still being written)
  FILES+=("$f")
done

TOTAL=${#FILES[@]}

# Exit early if there is nothing to do
if (( TOTAL == 0 )); then
  echo "No files to process."
  exit 0
fi

echo "Found $TOTAL file(s) to process."

COUNT=0

# ---------------------------------------------------------------------------
# Process each file
# ---------------------------------------------------------------------------
for INPUT in "${FILES[@]}"; do
  COUNT=$((COUNT + 1))

  echo "=============================="
  echo "[$COUNT/$TOTAL] Processing: $INPUT"

  # 1. Get creation time from metadata (this is the END time of the recording).
  #    ffprobe prints just the bare tag value, e.g. 2024-05-01T14:30:00.000000Z
  CREATION_TIME_RAW=$(ffprobe -v error \
    -show_entries format_tags=creation_time \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")

  # Without this metadata we can't work out the start time, so skip the file
  if [[ -z "$CREATION_TIME_RAW" ]]; then
    echo "No creation_time metadata in $INPUT, skipping."
    continue
  fi

  echo "Creation time (end): $CREATION_TIME_RAW"

  # 2. Parse to epoch seconds.
  #    First reformat the ISO timestamp: replace the "T" with a space and
  #    strip the fractional seconds/timezone suffix (everything from the first
  #    "."), leaving "YYYY-MM-DD HH:MM:SS". Then convert it to a Unix timestamp,
  #    treating the time as UTC (-u).
  CREATION_TIME_CLEAN=$(echo "$CREATION_TIME_RAW" | sed 's/T/ /; s/\..*//')
  CREATION_EPOCH=$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$CREATION_TIME_CLEAN" "+%s")

  # 3. Count frames in the first video stream.
  #    -count_packets makes ffprobe read through the file and count packets
  #    (one per frame), which is reliable even when metadata is missing.
  #    The CSV output can carry a trailing comma, so strip it with tr.
  FRAME_COUNT=$(ffprobe -v error -select_streams v:0 \
    -count_packets -show_entries stream=nb_read_packets \
    -of csv=p=0 "$INPUT" | tr -d ',')

  # Bail out if the count is empty or not a positive number
  if [[ -z "$FRAME_COUNT" || "$FRAME_COUNT" -le 0 ]]; then
    echo "Could not determine frame count for $INPUT, skipping."
    continue
  fi

  echo "Frame count: $FRAME_COUNT"

  # 4. Subtract to get the real start time.
  #    Each frame represents one real-world second, so the recording lasted
  #    FRAME_COUNT seconds. Start = end time - duration.
  START=$((CREATION_EPOCH - FRAME_COUNT))

  # Human-readable version of the start time, for logging only
  START_HUMAN=$(date -r "$START" "+%Y-%m-%d %H:%M:%S")
  echo "Derived start time: $START_HUMAN"

  # 5. Derive the output filename from the start time:
  #    28VL-DDMMYYYY-HHMMSS.mp4
  START_DATE=$(date -r "$START" "+%d%m%Y")
  START_TIME=$(date -r "$START" "+%H%M%S")
  OUTPUT="28VL-${START_DATE}-${START_TIME}.mp4"
  echo "Output file: $OUTPUT"

  # 6. Encode.
  #    -nostdin       : stop ffmpeg from consuming the script's stdin
  #    setpts=30.0*PTS: stretch timestamps 30x so each source frame lasts one
  #                     full second, which makes the clock overlay tick in
  #                     real time (one second per frame)
  #    drawtext       : burn a clock into the top-left corner. The
  #                     %{pts:localtime:START:FORMAT} expansion shows the
  #                     frame's timestamp offset from START (epoch seconds)
  #                     formatted as DD-MM-YYYY HH.MM.SS, white text on a
  #                     50% transparent black box
  #    -c:v libx264   : H.264 video codec
  #    -b:v 1M        : target a 1 Mbit/s bitrate
  #    -preset superfast : faster encoding at the cost of file size/efficiency
  #    -r 1           : output at 1 frame per second
  if ffmpeg -nostdin -i "$INPUT" -vf \
  "setpts=30.0*PTS, \
  drawtext=fontfile='/System/Library/Fonts/Supplemental/Arial.ttf': \
  text='%{pts\:localtime\:$START\:%d-%m-%Y %H.%M.%S}': \
  x=20: y=20: fontcolor=white: fontsize=96: box=1: boxcolor=black@0.5" \
  -c:v libx264 -b:v 1M -preset superfast -r 1 "$OUTPUT"; then

    # 7. Mark the original as processed (rename, don't delete), so the
    #    "complete_*" check at the top skips it on future runs
    mv "$INPUT" "complete_$INPUT"
    echo "Done: $OUTPUT (original renamed to complete_$INPUT)"
  else
    # Leave the original untouched so the script can be re-run to retry it
    echo "ffmpeg failed on $INPUT, leaving it unrenamed so it can be retried."
  fi

done

echo "=============================="
echo "Finished. Processed up to $TOTAL file(s)."

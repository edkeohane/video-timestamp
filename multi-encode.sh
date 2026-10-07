#!/bin/bash

shopt -s nullglob

# Build the list of files to process
FILES=()
for f in *input*.mp4; do
  [[ -f "$f" ]] || continue                    # real files only
  [[ "$f" == complete_* ]] && continue         # already processed
  [[ "$f" == *.download* ]] && continue        # pending downloads
  FILES+=("$f")
done

TOTAL=${#FILES[@]}

if (( TOTAL == 0 )); then
  echo "No files to process."
  exit 0
fi

echo "Found $TOTAL file(s) to process."

COUNT=0

for INPUT in "${FILES[@]}"; do
  COUNT=$((COUNT + 1))

  echo "=============================="
  echo "[$COUNT/$TOTAL] Processing: $INPUT"

  # 1. Get creation time from metadata (this is the END time)
  CREATION_TIME_RAW=$(ffprobe -v error \
    -show_entries format_tags=creation_time \
    -of default=noprint_wrappers=1:nokey=1 "$INPUT")

  if [[ -z "$CREATION_TIME_RAW" ]]; then
    echo "No creation_time metadata in $INPUT, skipping."
    continue
  fi

  echo "Creation time (end): $CREATION_TIME_RAW"

  # 2. Parse to epoch
  CREATION_TIME_CLEAN=$(echo "$CREATION_TIME_RAW" | sed 's/T/ /; s/\..*//')
  CREATION_EPOCH=$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$CREATION_TIME_CLEAN" "+%s")

  # 3. Count frames — strip trailing comma
  FRAME_COUNT=$(ffprobe -v error -select_streams v:0 \
    -count_packets -show_entries stream=nb_read_packets \
    -of csv=p=0 "$INPUT" | tr -d ',')

  if [[ -z "$FRAME_COUNT" || "$FRAME_COUNT" -le 0 ]]; then
    echo "Could not determine frame count for $INPUT, skipping."
    continue
  fi

  echo "Frame count: $FRAME_COUNT"

  # 4. Subtract to get real start time
  START=$((CREATION_EPOCH - FRAME_COUNT))

  START_HUMAN=$(date -r "$START" "+%Y-%m-%d %H:%M:%S")
  echo "Derived start time: $START_HUMAN"

  # 5. Derive output filename
  START_DATE=$(date -r "$START" "+%d%m%Y")
  START_TIME=$(date -r "$START" "+%H%M%S")
  OUTPUT="28VL-${START_DATE}-${START_TIME}.mp4"
  echo "Output file: $OUTPUT"

  # 6. Encode
  if ffmpeg -nostdin -i "$INPUT" -vf \
  "setpts=30.0*PTS, \
  drawtext=fontfile='/System/Library/Fonts/Supplemental/Arial.ttf': \
  text='%{pts\:localtime\:$START\:%d-%m-%Y %H.%M.%S}': \
  x=20: y=20: fontcolor=white: fontsize=96: box=1: boxcolor=black@0.5" \
  -c:v libx264 -b:v 1M -preset superfast -r 1 "$OUTPUT"; then

    # 7. Mark the original as processed (rename, don't delete)
    mv "$INPUT" "complete_$INPUT"
    echo "Done: $OUTPUT (original renamed to complete_$INPUT)"
  else
    echo "ffmpeg failed on $INPUT, leaving it unrenamed so it can be retried."
  fi

done

echo "=============================="
echo "Finished. Processed up to $TOTAL file(s)."

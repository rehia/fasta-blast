#!/usr/bin/env bash

# Usage/help message
show_help() {
  echo "Usage: $0 [--py | --perl] [directory]"
  echo
  echo "Checks the given directory (or current directory by default) for .fasta/.fas/.fst files and processes each one using:"
  echo "  ./web_blast.[pl|py] megablast core_nt <file>"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help message and exit"
  echo "  --py          Use web blast python version"
  echo "  --perl        Use web blast perl version (default if no option is given)"
}

# Default script is Perl
SCRIPT="./web_blast.pl"

# Parse first argument
case "$1" in
  -h|--help)
    show_help
    exit 0
    ;;
  --py)
    SCRIPT="./web_blast.py"
    shift
    ;;
  --perl)
    SCRIPT="./web_blast.pl"
    shift
    ;;
esac

# Use provided directory or default to current directory
DIR="${1:-.}"

# Check if directory exists
if [[ ! -d "$DIR" ]]; then
  echo "Error: '$DIR' is not a directory or doesn't exist."
  exit 1
fi

# Enable nullglob so unmatched patterns expand to nothing
shopt -s nullglob nocaseglob

# Find .fasta, .fas, .fst (case-insensitive)
FASTA_FILES=()
for ext in fasta fas fst; do
  for file in "$DIR"/*."$ext"; do
    [[ -f "$file" ]] && FASTA_FILES+=("$file")
  done
done

if [[ ${#FASTA_FILES[@]} -eq 0 ]]; then
  echo "Error: No .fasta, .fst or .fas files found in '$DIR'."
  exit 1
fi

# Collect output lines
RESULTS=()

for ((i = 0; i < ${#FASTA_FILES[@]}; i++)); do
  file="${FASTA_FILES[i]}"
  echo "Processing file: $file"

  output=$($SCRIPT megablast core_nt "$file")
  RESULTS+=("$output")

  # Sleep only between files
  if (( i < ${#FASTA_FILES[@]} - 1 )); then
    echo "Sleeping for 5 seconds to avoid spamming NCBI website..."
    sleep 5
  fi
done

# Print all collected lines together
# CSV header line (must match script output field order)
echo "sequence name,description,scientific name,max score,total score,query cover,e value,percent identity,accession length,accession,query length,sequence" > output.csv
printf "%s\n" "${RESULTS[@]}" >> output.csv

NOW=$( date '+%F_%H:%M:%S' )
mv output.csv "blast-$NOW.csv"

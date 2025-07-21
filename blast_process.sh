#!/usr/bin/env bash

# Usage/help message
show_help() {
  echo "Usage: $0 [directory]"
  echo
  echo "Checks the given directory (or current directory by default) for .fasta files and processes each one using:"
  echo "  ./web_blast.pl megablast core_nt <file.fasta>"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help message and exit"
}

# Parse arguments
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
  exit 0
fi

# Use provided directory or default to current directory
DIR="${1:-.}"

# Check if directory exists
if [[ ! -d "$DIR" ]]; then
  echo "Error: '$DIR' is not a directory or doesn't exist."
  exit 1
fi

# Check for .fasta files
shopt -s nullglob

# Match .fasta, .fas, and .fst (case-insensitive)
FASTA_FILES=()
for ext in fasta fas fst; do
  for file in "$DIR"/*."$ext"; do
    [[ -f "$file" ]] && FASTA_FILES+=("$file")
  done
done

if [[ ${#FASTA_FILES[@]} -eq 0 ]]; then
  echo "Error: No .fastai, .fst or .fas files found in '$DIR'."
  exit 1
fi

# Collect output lines
RESULTS=()

for ((i = 0; i < ${#FASTA_FILES[@]}; i++)); do
  file="${FASTA_FILES[i]}"
  echo "Processing file: $file"

  output=$(./web_blast.pl megablast core_nt "$file")
  RESULTS+=("$output")

  # Sleep only between files
  if (( i < ${#FASTA_FILES[@]} - 1 )); then
    echo "Sleeping for 5 seconds to avoid spamming NCBI website..."
    sleep 5
  fi
done

# Print all collected lines together
# CSV header line (must match Perl output field order)
echo "sequence name,description,scientific name,max score,total score,query cover,e value,percent identity,accession length,accession,query length,sequence" > output.csv
printf "%s\n" "${RESULTS[@]}" >> output.csv

NOW=$( date '+%F_%H:%M:%S' )
mv output.csv "blast-$NOW.csv"

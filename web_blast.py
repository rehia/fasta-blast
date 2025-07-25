#!/usr/bin/env python3
import sys
import os
import re
import time
import json
import requests
from urllib.parse import quote
from functools import reduce

# This script performs a BLAST query using NCBI's web service.
# It replicates the Perl script "web_blast.pl" but in Python 3.

USAGE = """usage: web_blast.py [--output json|csv] program database query [query]...
where program = megablast, blastn, blastp, rpsblast, blastx, tblastn, tblastx

example: web_blast.py blastp nr protein.fasta
example: web_blast.py rpsblast cdd protein.fasta
example: web_blast.py megablast nt dna1.fasta dna2.fasta
"""

BLAST_BASE = "https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi"


def csv_escape(value):
    # Escape quotes and wrap strings if necessary (simplified CSV formatting)
    s = str(value)
    if any(c in s for c in [',', ';', '"']):
        s = s.replace('"', '""')
        return f'"{s}"'
    return s


def read_first_fasta_info(path):
    # Get the filename without extension
    base = os.path.splitext(os.path.basename(path))[0]

    # Read all lines of the FASTA file
    with open(path, 'r') as fh:
        lines = fh.readlines()

    if lines and lines[0].startswith('>'):
        lines = lines[1:]

    seq = ''.join(lines)
    seq = re.sub(r'[\r\n]', '', seq)
    return base, seq


def parse_arguments(argv):
    # Check for optional --output flag
    output_format = "csv"
    args = argv[:]

    if args and args[0] == "--output":
        if len(args) < 2:
            sys.stderr.write(USAGE)
            sys.exit(1)
        output_format = args[1]
        if output_format not in ("csv", "json"):
            sys.stderr.write("Invalid output format. Use 'csv' or 'json'.\n")
            sys.exit(1)
        args = args[2:]

    if len(args) < 3:
        sys.stderr.write(USAGE)
        sys.exit(1)

    program = args[0]
    database = args[1]
    queries = args[2:]
    return output_format, program, database, queries


def main():
    output_format, program, database, queries = parse_arguments(sys.argv[1:])

    if program == "megablast":
        program = "blastn"
        params_extra = {"MEGABLAST": "on"}
    elif program == "rpsblast":
        program = "blastp"
        params_extra = {"SERVICE": "rpsblast"}
    else:
        params_extra = {}

    encoded_query = ''
    first = True
    basename = ""
    sequence = ""

    for q in queries:
        with open(q, 'r') as fh:
            for line in fh:
                encoded_query += quote(line)

        if first:
            basename, sequence = read_first_fasta_info(q)
            first = False

    args = {
        "CMD": "Put",
        "PROGRAM": program,
        "DATABASE": database,
        "QUERY": encoded_query,
    }
    args.update(params_extra)

    headers = {"User-Agent": "web_blast.py (Python requests)"}
    r = requests.get(BLAST_BASE, params=args, headers=headers)

    if not r.ok:
        sys.stderr.write(f"Failed to submit request: HTTP {r.status_code}\n")
        sys.exit(1)

    response_text = r.text

    # parse out the request id
    rid_match = re.search(r'^\s*RID\s*=\s*(\S+)', response_text, re.M)
    rid = rid_match.group(1) if rid_match else None

    # parse out the estimated time to completion
    rtoe_match = re.search(r'^\s*RTOE\s*=\s*(\d+)', response_text, re.M)
    rtoe = int(rtoe_match.group(1)) if rtoe_match else None

    if not rid or rtoe is None:
        sys.stderr.write("Could not parse RID or RTOE\n")
        sys.exit(1)

    print(f"Polling response with ID {rid} and estimated response time {rtoe} sec", file=sys.stderr)
    time.sleep(rtoe / 2)

    while True:
        time.sleep(5)
        poll_args = {"CMD": "Get", "FORMAT_OBJECT": "SearchInfo", "RID": rid}
        r = requests.get(BLAST_BASE, params=poll_args, headers=headers)
        response_text = r.text

        if re.search(r'\s+Status=WAITING', response_text):
            print("Searching...", file=sys.stderr)
            continue
        if re.search(r'\s+Status=FAILED', response_text):
            print(f"Search {rid} failed; please report to blast-help@ncbi.nlm.nih.gov.", file=sys.stderr)
            sys.exit(4)
        if re.search(r'\s+Status=UNKNOWN', response_text):
            print(f"Search {rid} expired.", file=sys.stderr)
            sys.exit(3)
        if re.search(r'\s+Status=READY', response_text):
            print("Search complete, retrieving results...", file=sys.stderr)
            break
        sys.exit(5)

    # retrieve and display results
    result_args = {"CMD": "Get", "FORMAT_TYPE": "JSON2_S", "RID": rid}
    r = requests.get(BLAST_BASE, params=result_args, headers=headers)
    data = r.json()

    hit = data["BlastOutput2"][0]["report"]["results"]["search"]["hits"][0]
    query_len = data["BlastOutput2"][0]["report"]["results"]["search"]["query_len"]

    description = hit["description"][0]["title"]
    scientific_name = hit["description"][0].get("sciname")
    accession = hit["description"][0]["accession"]
    hsps = hit["hsps"]

    max_bit_score = max(h["bit_score"] for h in hsps)
    total_bit_score = sum(h["bit_score"] for h in hsps)
    total_score = sum(h["score"] for h in hsps)
    total_identity = sum(h["identity"] for h in hsps)
    total_align_length = sum(h["align_len"] for h in hsps)

    query_cover = f"{(100 * total_align_length / query_len):.0f}%"
    percent_identity = f"{(100 * total_identity / total_align_length):.2f}%"

    e_value = hsps[0]["evalue"]
    accession_length = hit["len"]

    # Build the result dict
    result = {
        "basename": basename,
        "description": description,
        "scientific_name": scientific_name,
        "max_score": max_bit_score,
        "total_score": total_bit_score,
        "query_cover": query_cover,
        "e_value": e_value,
        "percent_identity": percent_identity,
        "accession_length": accession_length,
        "accession": accession,
        "query_length": query_len,
        "sequence": sequence
    }

    if output_format == "json":
        print(json.dumps(result, indent=2))
    else:
        # CSV
        fields = [
            basename, description, scientific_name,
            max_bit_score, total_bit_score, query_cover,
            e_value, percent_identity, accession_length,
            accession, query_len, sequence
        ]
        fields = [csv_escape(v) for v in fields]
        print(",".join(fields))

    sys.exit(0)


if __name__ == "__main__":
    sys.exit(main())


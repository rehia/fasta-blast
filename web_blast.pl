#!/usr/bin/perl

# $Id: web_blast.pl,v 1.10 2016/07/13 14:32:50 merezhuk Exp $
#
# ===========================================================================
#
#                            PUBLIC DOMAIN NOTICE
#               National Center for Biotechnology Information
#
# This software/database is a "United States Government Work" under the
# terms of the United States Copyright Act.  It was written as part of
# the author's official duties as a United States Government employee and
# thus cannot be copyrighted.  This software/database is freely available
# to the public for use. The National Library of Medicine and the U.S.
# Government have not placed any restriction on its use or reproduction.
#
# Although all reasonable efforts have been taken to ensure the accuracy
# and reliability of the software and data, the NLM and the U.S.
# Government do not and cannot warrant the performance or results that
# may be obtained by using this software or data. The NLM and the U.S.
# Government disclaim all warranties, express or implied, including
# warranties of performance, merchantability or fitness for any particular
# purpose.
#
# Please cite the author in any work or product based on this material.
#
# ===========================================================================
#
# This code is for example purposes only.
#
# Please refer to https://ncbi.github.io/blast-cloud/dev/api.html
# for a complete list of allowed parameters.
#
# Please do not submit or retrieve more than one request every two seconds.
#
# Results will be kept at NCBI for 24 hours. For best batch performance,
# we recommend that you submit requests after 2000 EST (0100 GMT) and
# retrieve results before 0500 EST (1000 GMT).
#
# ===========================================================================
#
# return codes:
#     0 - success
#     1 - invalid arguments
#     2 - no hits found
#     3 - rid expired
#     4 - search failed
#     5 - unknown error
#
# ===========================================================================

# use strict;
# use warnings;
use URI::Escape;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use JSON qw(decode_json encode_json);
use List::Util qw(max sum);
use File::Basename;

my $ua = LWP::UserAgent->new;

my $argc = $#ARGV + 1;

if ($argc < 3)
    {
    print "usage: web_blast.pl program database query [query]...\n";
    print "where program = megablast, blastn, blastp, rpsblast, blastx, tblastn, tblastx\n\n";
    print "example: web_blast.pl blastp nr protein.fasta\n";
    print "example: web_blast.pl rpsblast cdd protein.fasta\n";
    print "example: web_blast.pl megablast nt dna1.fasta dna2.fasta\n";

    exit 1;
}

my $program = shift;
my $database = shift;

if ($program eq "megablast")
    {
    $program = "blastn&MEGABLAST=on";
    }

if ($program eq "rpsblast")
    {
    $program = "blastp&SERVICE=rpsblast";
    }

# read and encode the queries
my ($basename, $sequence);
my $encoded_query = '';
my $first = 1;

foreach my $query (@ARGV) {
    open(my $fh, '<', $query) or die "Cannot open $query: $!";
    while (<$fh>) {
        $encoded_query .= uri_escape($_);
    }
    close $fh;

    if ($first) {
        # Get the filename without extension
        ($basename) = fileparse($query, qr/\.[^.]*/);

        # Re-open to extract sequence
        open(my $seq_fh, '<', $query) or die "Cannot open $query: $!";
        my @lines = <$seq_fh>;
        close $seq_fh;

        shift @lines if $lines[0] =~ /^>/;
        $sequence = join('', @lines);
        $sequence =~ s/[\r\n]//g;

        $first = 0;
    }
}

# build the request
my $args = "CMD=Put&PROGRAM=$program&DATABASE=$database&QUERY=" . $encoded_query;

# print STDERR "Running query with params:" . $args . "\n";

$ENV{HTTPS_CA_DIR}    = '/etc/ssl/certs';
$ENV{HTTPS_CA_FILE}    = '/etc/ssl/certs/ca-certificates.crt';
$ua->ssl_opts(verify_hostname => 0);

my $req = new HTTP::Request GET => 'https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi?' . $args;
# $req->content_type('application/x-www-form-urlencoded');
# $req->content($args);

# get the response
my $response = $ua->request($req);

# print STDERR "Request submission response is : " . $response->content . "\n\n";

# parse out the request id
$response->content =~ /^    RID = (.*$)/m;
my $rid=$1;

# parse out the estimated time to completion
$response->content =~ /^    RTOE = (.*$)/m;
my $rtoe=$1;

print STDERR "Polling response with ID " . $rid . " and estimated response time " . $rtoe . " sec\n";

# wait for search to complete
sleep $rtoe;

# poll for results
while (true)
    {
    sleep 5;

    $req = new HTTP::Request GET => "https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID=$rid";
    $response = $ua->request($req);

    # print STDERR "Request status is : " . $response->content . "\n";

    if ($response->content =~ /\s+Status=WAITING/m)
        {
        print STDERR "Searching...\n";
        next;
        }

    if ($response->content =~ /\s+Status=FAILED/m)
        {
        print STDERR "Search $rid failed; please report to blast-help\@ncbi.nlm.nih.gov.\n";
        exit 4;
        }

    if ($response->content =~ /\s+Status=UNKNOWN/m)
        {
        print STDERR "Search $rid expired.\n";
        exit 3;
        }

    if ($response->content =~ /\s+Status=READY/m) 
        {
            # print STDERR "Ready status content: " . $response->content . "\n";
        # if ($response->content =~ /\s+ThereAreHits=yes/m)
            # {
             print STDERR "Search complete, retrieving results...\n";
            last;
            # }
        # else
            # {
            # print STDERR "No hits found.\n";
            # exit 2;
            # }
        }

    # if we get here, something unexpected happened.
    exit 5;
    } # end poll loop

# retrieve and display results
$req = new HTTP::Request GET => "https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi?CMD=Get&FORMAT_TYPE=JSON2_S&RID=$rid";
$response = $ua->request($req);

# print STDERR "Result content: " . $response->decoded_content . "\n";

# Decode the JSON
my $json_text = $response->decoded_content;
my $data = decode_json($json_text);

# Extract the first hit
my $hit = $data->{BlastOutput2}[0]{report}{results}{search}{hits}[0];
my $query_len = $data->{BlastOutput2}[0]{report}{results}{search}{query_len};

# Extract values
my $description     = $hit->{description}[0]{title};
my $scientific_name = $hit->{description}[0]{sciname};
my $accession = $hit->{description}[0]{accession};
my @hsps            = @{ $hit->{hsps} };

my $max_bit_score     = max map { $_->{bit_score} } @hsps;
my $total_bit_score   = sum map { $_->{bit_score} } @hsps;
my $total_score       = sum map { $_->{score} } @hsps;
my $total_identity    = sum map { $_->{identity} } @hsps;

my $query_cover      = sprintf("%.1f%%", 100 * $total_score / $query_len);
my $percent_identity = sprintf("%.1f%%", 100 * $total_identity / $query_len);

my $e_value           = $hsps[0]{evalue};
my $accession_length  = $hit->{len};

# Build the result hash
# my $result = {
#     "description"       => $description,
#     "scientific name"   => $scientific_name,
#     "max score"         => $max_bit_score,
#     "total score"       => $total_bit_score,
#     "query cover"       => $query_cover,
#     "e value"           => $e_value,
#     "percent identity"  => $percent_identity,
#     "accession length"  => $accession_length,
# };

# # Output the result as JSON
# my $json = JSON->new->pretty->allow_nonref;
# print $json->encode($result);

# Prepare fields in order
my @fields = (
    $basename,
    $description,
    $scientific_name,
    $max_bit_score,
    $total_bit_score,
    sprintf("%.1f%%", 100 * $total_score / $query_len),
    $e_value,
    sprintf("%.1f%%", 100 * $total_identity / $query_len),
    $accession_length,
    $accession,
    $sequence
);

# Escape quotes and wrap strings if necessary (simplified CSV formatting)
@fields = map {
    if (/[,"]/) { # if field contains a comma or quote
        s/"/""/g;  # escape quotes by doubling them
        qq("$_")   # wrap in quotes
    } else {
        $_
    }
} @fields;

# Print as a single CSV line
print join(",", @fields), "\n";

exit 0;

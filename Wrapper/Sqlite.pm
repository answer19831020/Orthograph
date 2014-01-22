#--------------------------------------------------
# This file is part of Orthograph.
# Copyright 2013 Malte Petersen <mptrsen@uni-bonn.de>
# 
# Orthograph is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
# 
# Orthograph is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with
# Orthograph. If not, see http://www.gnu.org/licenses/.
#-------------------------------------------------- 
=head1 NAME 

Wrapper::Sqlite

=head1 SYNOPSIS

  use Wrapper::Sqlite;

  my $dbh = Wrapper::Sqlite::db_dbh();
  do_stuff_with_dbh();
  undef $dbh;

  Wrapper::Sqlite::do($query);

  my $result = Wrapper::Sqlite::get($query);

=head1 DESCRIPTION

Wrapper module that provides db functions. Deals with specific queries to
handle the complex database structure in the Orthograph pipeline.

=cut

package Wrapper::Sqlite;
use strict;
use warnings;
use Carp;
use Exporter;
use FindBin;        # locate the dir of this script during compile time
use lib $FindBin::Bin;                 # $Bin is the directory of the original script
use Orthograph::Config;                # configuration parser getconfig()
use Data::Dumper;
use DBI;
use DBD::SQLite;

my $config = $Orthograph::Config::config;  # copy config

# db settings
my $database                = $config->{'sqlite-database'};
my $db_timeout              = $config->{'sqlite-timeout'};
my $sleep_for               = 10;

my $db_table_aaseqs         = $config->{'db_table_aaseqs'};
my $db_table_blast          = $config->{'db_table_blast'};
my $db_table_blastdbs       = $config->{'db_table_blastdbs'};
my $db_table_ests           = $config->{'db_table_ests'};
my $db_table_hmmsearch      = $config->{'db_table_hmmsearch'};
my $db_table_log_evalues    = $config->{'db_table_log_evalues'};
my $db_table_scores         = $config->{'db_table_scores'};
my $db_table_ntseqs         = $config->{'db_table_ntseqs'};
my $db_table_ogs            = $config->{'db_table_ogs'};
my $db_table_orthologs      = $config->{'db_table_orthologs'};
my $db_table_seqpairs       = $config->{'db_table_sequence_pairs'};
my $db_table_set_details    = $config->{'db_table_set_details'};
my $db_table_taxa           = $config->{'db_table_taxa'};
my $db_col_aaseq            = 'aa_seq';
my $db_col_digest           = 'digest';
my $db_col_end              = 'end';
my $db_col_env_end          = 'env_end';
my $db_col_env_start        = 'env_start';
my $db_col_evalue           = 'evalue';
my $db_col_hmm_end          = 'hmm_end';
my $db_col_hmm_start        = 'hmm_start';
my $db_col_header           = 'header';
my $db_col_id               = 'id';
my $db_col_log_evalue       = 'log_evalue';
my $db_col_score            = 'score';
my $db_col_name             = 'name';
my $db_col_ntseq            = 'nt_seq';
my $db_col_orthoid          = 'ortholog_gene_id';
my $db_col_query            = 'query';
my $db_col_setid            = 'setid';
my $db_col_sequence         = 'sequence';
my $db_col_seqpair          = 'sequence_pair';
my $db_col_start            = 'start';
my $db_col_target           = 'target';
my $db_col_taxid            = 'taxid';
my $outdir                  = $config->{'output-directory'};
my $orthoset                = $config->{'ortholog-set'};
my $quiet                   = $config->{'quiet'};
my $reftaxa                 = $config->{'reference-taxa'};
# substitution character for selenocysteine, which normally leads to blast freaking out
my $u_subst                 = $config->{'substitute-u-with'};
my $sets_dir                = $config->{'sets-dir'};
my $species_name            = $config->{'species-name'};
my $g_species_id            = undef;	# global variable
my $verbose                 = $config->{'verbose'};
my $debug                   = $config->{'debug'};
#}}}

# was the database specified and does it exist?
if (not defined $database) {
	fail_and_exit('SQLite database not specified');
}
elsif (!-f $database) {
	fail_and_exit("SQLite database '$database' not found");
}

=head1 FUNCTIONS

=cut

sub fail_and_exit {
	my $msg = shift @_;
	print STDERR 'Fatal: ' . $msg . "\n";
	exit 1;
}

=head2 db_dbh()

Get a database handle

Arguments: -

Returns: Database handle

=cut

sub get_dbh {#{{{
	my $dbh = undef;
	my $slept = 0;

	until ($dbh = DBI->connect("DBI:SQLite:$database")) {
		if ($slept >= $db_timeout) { 
			carp "Warning: Connection retry timeout exceeded\n" and return undef;
		}
		carp "Warning: Connection failed, retrying in $sleep_for seconds\n";
		sleep $sleep_for;
		$slept += $sleep_for;
	}

	if ($dbh) { return $dbh }
	return undef;
}#}}}

=head2 db_get($query)

Get from the database the result of a SQL query

Expects: QUERY as a string literal

Returns: Reference to array of arrays (result lines->fields)

=cut

sub db_get {#{{{
	my $query = shift;
	unless ($query) { croak "Usage: db_get(QUERY, ARGS)\n" }
	my @args = @_;
  # prepare anonymous array
	my $results = [ ];
  # connect and fetch stuff
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, @args);
	while (my @result = $sth->fetchrow_array() ) {
		push(@$results, \@result);
	}
	$sth->finish();
	$dbh->disconnect; # disconnect ASAP
	return $results;
}#}}}

=head2 db_do($query)

Connect to a database, execute a single $query (for repetitive queries, you
better do that by hand for performance reasons).

Expects: scalar string SQL query. 

Returns 1 on result, dies otherwise.

=cut

sub db_do {#{{{
	my $query = shift;
	unless ($query) { croak "Usage: db_do(QUERY)\n" }
	my @fields = @_;
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, @fields);
	$dbh->disconnect();
	return 1;
}#}}}


sub drop_tables {
	my %t = @_;
	print 'DROPing tables: ', join(", ", values(%t)), "\n" if $verbose;
	my $dbh = get_dbh() or fail_and_exit("Couldn't get database connection");
	foreach my $table (keys(%t)) {
		$dbh->do("DROP TABLE IF EXISTS $t{$table}") or die "Could not execute drop query: $!\n";
	}
	$dbh->disconnect();
}

sub create_tables {
	my %t = @_;
	# the queries for the individual tables
	my %create_table = (#{{{
		# table: blastdbs
		'blastdbs' => "CREATE TABLE `$t{'blastdbs'}` (
			`id`           INTEGER PRIMARY KEY,
			`setid`        INT UNSIGNED DEFAULT NULL UNIQUE,
			`blastdb_path` VARCHAR(255) DEFAULT NULL)",
		
		# table: ogs
		'ogs' => "CREATE TABLE `$t{'ogs'}` (
			`id`           INTEGER PRIMARY KEY,
			`type`         INT(1),
			`taxid`        INT UNSIGNED NOT NULL UNIQUE,
			`version`      VARCHAR(255))",
		
		# table: ortholog_set
		'ortholog_set' => "CREATE TABLE `$t{'orthologs'}` (
			`id`               INTEGER PRIMARY KEY,
			`setid`            INT UNSIGNED NOT NULL,
			`ortholog_gene_id` VARCHAR(10)  NOT NULL,
			`sequence_pair`    INT UNSIGNED NOT NULL,
			UNIQUE (setid, ortholog_gene_id, sequence_pair))",

		# table: sequence_pairs
		'sequence_pairs' => "CREATE TABLE `$t{'seqpairs'}` (
			`id`           INTEGER PRIMARY KEY,
			`taxid`        INT    UNSIGNED,
			`ogs_id`       INT    UNSIGNED,
			`aa_seq`       INT    UNSIGNED UNIQUE,
			`nt_seq`       INT    UNSIGNED UNIQUE, 
			`date`         INT    UNSIGNED,
			`user`         INT    UNSIGNED)",

		# table: sequences_aa
		'aa_sequences' => "CREATE TABLE `$t{'aaseqs'}` (
			`id`           INTEGER PRIMARY KEY,
			`taxid`        INT             NOT NULL, 
			`header`       VARCHAR(512)    UNIQUE,
			`sequence`     MEDIUMBLOB,
			`user`         INT UNSIGNED,
			`date`         INT UNSIGNED)",

		# table: sequences_nt
		'nt_sequences' => "CREATE TABLE `$t{'ntseqs'}` (
			`id`           INTEGER PRIMARY KEY,
			`taxid`        INT             NOT NULL, 
			`header`       VARCHAR(512)    UNIQUE,
			`sequence`     MEDIUMBLOB,
			`user`         INT UNSIGNED,
			`date`         INT UNSIGNED)",

		# table: set_details
		'set_details' => "CREATE TABLE `$t{'set_details'}` (
			`id`           INTEGER PRIMARY KEY,
			`name`         VARCHAR(255) UNIQUE,
			`description`  BLOB)",

		# table: taxa
		'taxa' => "CREATE TABLE `$t{'taxa'}` (
			`id`           INTEGER PRIMARY KEY,
			`name`         VARCHAR(20)  UNIQUE,
			`longname`     VARCHAR(255), 
			`core`         TINYINT UNSIGNED NOT NULL)",
		
		# table: users
		'users' => "CREATE TABLE `$t{'users'}` (
			`id`           INTEGER PRIMARY KEY,
			`name`         VARCHAR(255) UNIQUE)",
		# table: seqtypes
		'seqtypes' => "CREATE TABLE `$t{'seqtypes'}` (
			`id`           INTEGER PRIMARY KEY,
			`type`         CHAR(3)     UNIQUE)",
	);#}}}

	my @indices = (
		# indices for sequences_aa
		"CREATE INDEX IF NOT EXISTS $t{'aaseqs'}_taxid  ON $t{'aaseqs'} (taxid)",
		"CREATE INDEX IF NOT EXISTS $t{'ntseqs'}_taxid  ON $t{'ntseqs'} (taxid)",
		"CREATE INDEX IF NOT EXISTS $t{'aaseqs'}_header  ON $t{'aaseqs'} (header)",
		"CREATE INDEX IF NOT EXISTS $t{'ntseqs'}_header  ON $t{'ntseqs'} (header)",
	);

	# to start off with nt and aa sequence types
	my $insert_seqtypes = "INSERT OR IGNORE INTO $t{'seqtypes'} (type) VALUES ('nt'),('aa')";

	my $dbh = get_dbh();
	foreach (values %create_table) {
		print $_, ";\n" if $verbose;
		$dbh->do($_) or die "Could not exec query: $!\n";
	}
	foreach (@indices) {
		print $_, ";\n" if $verbose;
		$dbh->do($_) or die "Could not exec query: $!\n";
	}
	$dbh->do($insert_seqtypes);	# start off with 'nt' and 'aa' seqtypes
	$dbh->disconnect;
}


=head2 get_ortholog_sets()

Get list of ortholog sets from the database

Arguments: none

Returns: hash reference of set names => description

=cut

sub get_ortholog_sets {#{{{
	my %sets = ();
	my $query = "SELECT * FROM $db_table_set_details";
	my $data = &Wrapper::db::db_get($query);
	foreach my $item (@$data) {
		$sets{$$item[1]} = $$item[2];
	}
	return(\%sets);
}#}}}

=head2 list_ogs

Get list of OGS in the database

Arguments: none

Returns: array reference (list of OGS)

=cut

sub get_list_of_ogs {#{{{
	my %ogslist = ();
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $query = "SELECT DISTINCT $db_table_taxa.name , $db_table_ogs.version
		FROM $db_table_aaseqs
		INNER JOIN $db_table_seqpairs
			ON $db_table_aaseqs.id  = $db_table_seqpairs.aa_seq
		INNER JOIN $db_table_taxa
			ON $db_table_seqpairs.taxid = $db_table_taxa.id
		INNER JOIN $db_table_ogs
			ON $db_table_taxa.id = $db_table_ogs.taxid"
	;
	my $data = &Wrapper::db::db_get($query);
	foreach my $item (@$data) {
		$ogslist{$$item[0]} = $$item[1];
	}
	return(\%ogslist);
}#}}}


=head2 get_ortholog_groups_for_set($setid)

Returns a hashref of hashrefs to create an ortholog set from. Each key in the hashref (the ortholog group ID) is a hashref of sequence_ID => sequence.

=cut

sub get_ortholog_groups_for_set {
	my $setid = shift @_ or croak "Usage: Wrapper::db::get_ortholog_groups_for_set(SETID)";
	my $data = {};
	my $query = "SELECT o.ortholog_gene_id, a.id, a.sequence
		FROM $db_table_orthologs         AS o
    INNER JOIN $db_table_seqpairs    AS p
    ON o.sequence_pair = p.id
    INNER JOIN $db_table_aaseqs      AS a
    ON a.id = p.aa_seq
    INNER JOIN $db_table_set_details AS d
    ON d.id = o.setid
    WHERE d.id = ?";

	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $setid);
	while (my @row = $sth->fetchrow_array()) {
		# load the whole set into memory, i don't give a frak
		$$data{$row[0]}{$row[1]} = $row[2];
	}
	$dbh->disconnect();	# disc asap

	return $data;
}

sub get_transcripts {
	my $specid = shift or croak "Usage: Wrapper::db::get_transcripts(SPECIESID, TYPE)";
	my $type = shift or croak "Usage: Wrapper::db::get_transcripts(SPECIESID, TYPE)";
	my $query = "SELECT digest, sequence
		FROM $db_table_ests
		WHERE taxid = ?
		AND type = ?";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $specid, $type);
	my $data = $sth->fetchall_arrayref();
	$sth->finish();
	$dbh->disconnect();
	return $data;
}

# Sub: get_hmmresults
# Get hmmsearch results from the database.
# Arguments: scalar string hmmsearch query
# Returns: reference to array of arrays
sub get_hmmresults {#{{{
	my ($hmmquery, $taxid) = @_ or croak "Usage: Wrapper::db::get_hmmresults(HMMQUERY)";
	# disable query cache for this one
	my $query_get_sequences = "SELECT SQL_NO_CACHE $db_table_ests.digest,
		  $db_table_ests.sequence,
		  $db_table_hmmsearch.env_start,
		  $db_table_hmmsearch.env_end
		FROM $db_table_ests 
		INNER JOIN $db_table_hmmsearch
		ON $db_table_hmmsearch.target = $db_table_ests.digest
		WHERE $db_table_hmmsearch.query = ?
		AND $db_table_hmmsearch.taxid = ?";

	# get the sequences from the database (as array->array reference)
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query_get_sequences);
	do {
		$sth->execute($hmmquery, $taxid);
	} while ($sth->err);
	my $results = $sth->fetchall_arrayref();
	$sth->finish();
	$dbh->disconnect();
	return $results;
}#}}}

=head2 get_taxa_in_all_sets

Get a list of sets associated with the included taxa.

Arguments: None

Returns: hash of scalars

=cut
sub get_taxa_in_all_sets {
	my %setlist = ();
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $query = "SELECT DISTINCT $db_table_set_details.name, $db_table_taxa.name
		FROM $db_table_seqpairs
		INNER JOIN $db_table_taxa
			ON $db_table_seqpairs.taxid = $db_table_taxa.id
		INNER JOIN $db_table_orthologs
			ON $db_table_orthologs.sequence_pair = $db_table_seqpairs.id 
		INNER JOIN $db_table_set_details
			ON $db_table_orthologs.setid = $db_table_set_details.id"
	;
	my $data = &db_get($query) or croak();
	foreach my $row (@$data) {
		$setlist{$$row[0]} .= ' ' . $$row[1];
	}
	return %setlist;
}

=head2 get_taxa_in_set(SETNAME)

Returns a list of taxon names for a named set.

Arguments: scalar string SETNAME

Returns: array of scalars

=cut
sub get_taxa_in_set {
	my $set_id = shift @_;
	unless ($set_id) { croak("Usage: get_taxa_in_set(SETNAME)") }
	my @reftaxa;
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $query = "SELECT DISTINCT $db_table_set_details.name, $db_table_taxa.name
		FROM $db_table_seqpairs
		INNER JOIN $db_table_taxa
			ON $db_table_seqpairs.taxid = $db_table_taxa.id
		INNER JOIN $db_table_orthologs
			ON $db_table_orthologs.sequence_pair = $db_table_seqpairs.id 
		INNER JOIN $db_table_set_details
			ON $db_table_orthologs.setid = $db_table_set_details.id
		WHERE $db_table_set_details.id = '$set_id'"
	;
	my $data = &db_get($query);
	foreach my $row (@$data) {
		push(@reftaxa, $$row[1]);
	}
	return @reftaxa;
}

=head2 get_number_of_ests_for_specid(ID)

Returns the number of EST sequences (transcripts) for a given species id.

Argument: scalar int ID

Returns: scalar int 

=cut

sub get_number_of_ests_for_specid {
	my $specid = shift @_ or croak "Usage: get_number_of_ests_for_specid(SPECID)";

	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $result = &db_get("SELECT COUNT(*) FROM $db_table_ests");

	return $$result[0][0];
}

sub get_taxids_in_set {
	my $setid = shift @_ or croak "Usage: get_taxids_in_set(SETID)";

	# get list of taxon names for this set
	my @taxa = &get_taxa_in_set($setid);

	# make a string for the next query
	my $taxa_string = join ',', map { $_ = "'$_'" } @taxa;

	# get the taxids for them
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $taxids = &db_get("SELECT id FROM $db_table_taxa WHERE name IN ($taxa_string)");

	return $taxids;
}

sub get_number_of_ests_for_set {
	my $setid = shift @_ or croak "Usage: get_taxids_in_set(SETID)";

	# get list of taxids for this set
	my $taxids = &get_taxids_in_set($setid);

	# make a fucking string out of these fucking fucks
	my $taxids_string = join ',', map { $$_[0] = "'$$_[0]'" } @$taxids;

	# get the number of aaseqs for those taxids
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $aaseqs = &db_get("SELECT COUNT(*) FROM  $db_table_aaseqs WHERE $db_table_aaseqs.taxid IN ($taxids_string)");

	return $$aaseqs[0][0];
}

=head2 get_aaseqs_for_set(SETID)

Returns a hashref for all aa sequences of taxa in a set, for creation of a BLAST database.
Don't forget to undef this ref (or let it go out of scope), as it is potentially very large!

Arguments: scalar int TAXID

Returns: hashref { ID => SEQ }

=cut
sub get_aaseqs_for_set {
	my $setid = shift @_ or croak "Usage: get_aaseqs_for_set(SETID)";

	# get the taxids for them
	my $taxids = &get_taxids_in_set($setid);

	# make a fucking string out of these fucking fucks
	my $taxids_string = join ',', map { $$_[0] = "'$$_[0]'" } @$taxids;

	# get the aaseqs for those taxids
	# this is a potentially very large collection, i hope that's fine with you
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $aaseqs = &db_get("SELECT $db_table_aaseqs.id, $db_table_aaseqs.sequence FROM  $db_table_aaseqs WHERE $db_table_aaseqs.taxid IN ($taxids_string)");

	$aaseqs = { map { $$_[0] => $$_[1] } @$aaseqs };
	return $aaseqs;
}


=head2 get_taxid_for_species(SPECIESNAME)

Returns the taxid for a named species.

Arguments: scalar string SPECIESNAME

Returns: scalar int TAXID

=cut
sub get_taxid_for_species {
	my $species_name = shift(@_);
	unless ($species_name) { croak("Usage: get_taxid_for_species(SPECIESNAME)") }
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $query = "SELECT id FROM $db_table_taxa WHERE core = 0 AND longname = '$species_name'";
	my $result = &db_get($query);
	if ($result) { 
		$g_species_id = $$result[0][0];
		return $$result[0][0];
	}
	return 0;
}

=head2 get_set_id(SETNAME)

get the set id for a named set. 

Arguments: scalar string SETNAME

Returns: scalar int SETID

=cut
sub get_set_id {
	my $setname = shift(@_);
	unless ($setname) { croak("Usage: get_set_id(SETNAME)") }
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $query = "SELECT id FROM $db_table_set_details WHERE name = '$setname'";
	my $result = &db_get($query);
	if ( scalar(@$result) > 1 ) { 
		warn("Warning: Multiple sets of the same name!\n");
		return $$result[0][0];
	}
	return $$result[0][0];
}

=head2 set_exists(SETNAME)

Tests whether a named set exists in the database. Returns 1 on success (the set
exists), 0 otherwise.

=cut

sub set_exists {
	my $set = shift;
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare("SELECT * FROM $db_table_set_details WHERE $db_col_name = ? LIMIT 1");
	$sth = execute($sth, $db_timeout, $set);
	my $result = $sth->fetchrow_arrayref;
	if ( $$result[0] ) { return 1 }
	return 0;
}

=head2 insert_taxon_into_table(TAXON_NAME)

Inserts a (non-core) taxon into the database. The taxon shorthand will be NULL
and the 'core' switch will be 0.

Returns the newly generated taxon ID.

=cut

sub insert_taxon_into_table {
	my $species_name = shift(@_);
	unless ($species_name) { croak("Usage: Wrapper::db::insert_taxon_into_table(SPECIESNAME)") }
	if (my $taxid = &get_taxid_for_species($species_name)) { return $taxid }
	my $query = "INSERT IGNORE INTO $db_table_taxa (longname, core) VALUES (?, ?)";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $species_name, 0);
	$dbh->disconnect();

	$g_species_id = &get_taxid_for_species($species_name) or croak;
	return $g_species_id;
}

sub create_log_evalues_view {
	unless (scalar @_ == 1) { croak 'Usage: Wrapper::db::create_log_evalues_view($species_id)' }
	my $taxid = shift;
	my $query_create_log_evalues = "CREATE OR REPLACE VIEW $db_table_log_evalues AS
	  SELECT $db_table_hmmsearch.$db_col_log_evalue AS $db_col_log_evalue,
	    COUNT($db_table_hmmsearch.$db_col_log_evalue) AS `count`
	  FROM $db_table_hmmsearch
	  WHERE $db_table_hmmsearch.$db_col_taxid = ?
	  GROUP BY $db_table_hmmsearch.$db_col_log_evalue
	  ORDER BY $db_table_hmmsearch.$db_col_log_evalue";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query_create_log_evalues);
	$sth = execute($sth, $db_timeout, $taxid);
	$dbh->disconnect();
	return 1;
}
	
sub create_scores_view {
	unless (scalar @_ == 1) { croak 'Usage: Wrapper::db::create_scores_view($species_id)' }
	my $taxid = shift;
	my $query_create_scores_view = "CREATE OR REPLACE VIEW $db_table_scores AS
	  SELECT $db_table_hmmsearch.$db_col_score AS $db_col_score,
	    COUNT($db_table_hmmsearch.$db_col_score) AS `count`
	  FROM $db_table_hmmsearch
	  WHERE $db_table_hmmsearch.$db_col_taxid = ?
	  GROUP BY $db_table_hmmsearch.$db_col_score
	  ORDER BY $db_table_hmmsearch.$db_col_score DESC";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query_create_scores_view);
	$sth = execute($sth, $db_timeout, $taxid);
	$dbh->disconnect();
	return 1;
}
	


# get a orthoid => list_of_aaseq_ids relationship from the db
sub get_orthologs_for_set_hashref {
	my $setid = shift(@_);
	unless ($setid) { croak("Usage: get_orthologs_for_set(SETID)") }
	my $query = "SELECT DISTINCT
		$db_table_orthologs.ortholog_gene_id,
		$db_table_aaseqs.id 
		FROM $db_table_orthologs 
		INNER JOIN $db_table_seqpairs 
			ON $db_table_orthologs.sequence_pair = $db_table_seqpairs.id
		INNER JOIN $db_table_aaseqs
			ON $db_table_seqpairs.aa_seq = $db_table_aaseqs.id
		INNER JOIN $db_table_set_details 
			ON $db_table_orthologs.setid = $db_table_set_details.id
		WHERE $db_table_set_details.id = ?";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $setid);
	my $result = { };
	while (my $line = $sth->fetchrow_arrayref()) {
		push( @{$$result{$$line[0]}}, $$line[1] );
	}
	$sth->finish;
	$dbh->disconnect;
	return $result;
}

=head2 get_ortholog_group($orthoid)

Get a specific ortholog group, i.e. aa headers and sequences.

=cut

sub get_ortholog_group {
	my $setid   = shift;
	my $orthoid = shift;
	my $query = "SELECT 
		$db_table_aaseqs.$db_col_header, $db_table_aaseqs.$db_col_sequence
		FROM $db_table_aaseqs
		INNER JOIN $db_table_seqpairs
			ON $db_table_aaseqs.$db_col_id = $db_table_seqpairs.$db_col_aaseq
		INNER JOIN $db_table_orthologs
			ON $db_table_seqpairs.$db_col_id = $db_table_orthologs.$db_col_seqpair
		AND   $db_table_orthologs.$db_col_setid = ?
		AND   $db_table_orthologs.$db_col_orthoid = ?";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $setid, $orthoid);
	my $data = $sth->fetchall_arrayref();
	return $data;
}

sub get_ortholog_group_nucleotide {
	my $setid   = shift;
	my $orthoid = shift;
	my $query = "SELECT 
		$db_table_ntseqs.$db_col_header, $db_table_ntseqs.$db_col_sequence
		FROM $db_table_ntseqs
		INNER JOIN $db_table_seqpairs
			ON $db_table_ntseqs.$db_col_id = $db_table_seqpairs.$db_col_ntseq
		INNER JOIN $db_table_orthologs
			ON $db_table_seqpairs.$db_col_id = $db_table_orthologs.$db_col_seqpair
		AND   $db_table_orthologs.$db_col_setid = ?
		AND   $db_table_orthologs.$db_col_orthoid = ?";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $setid, $orthoid);
	my $data = $sth->fetchall_arrayref();
	return $data;
}

=head2 get_hitlist_hashref(SPECIESID, SETID)

Get the results in the form:

  evalue => {
    orthoid => [
      blast_hit => {
        blasteval => e-value,
        taxname_of_hit => string,
      },
      etc.
    ],
    orthoid2 => [
      blast_hit,
      blast_hit,
    ]
  }

Arguments: scalar int SPECIESID, scalar int SETID

Returns: hashref of hashrefs of arrayrefs of hashrefs - lol

=cut

sub get_hitlist_hashref {
	scalar @_ == 4 or croak("Usage: get_hitlist_for(SPECIESID, SETID, LIMIT, OFFSET)");
	my ($specid, $setid, $limit, $offset) = @_;
	my $query = "SELECT DISTINCT
		$db_table_hmmsearch.evalue,
		$db_table_orthologs.ortholog_gene_id, 
		$db_table_hmmsearch.target,
		$db_table_ests.header,
		$db_table_ests.sequence,
		$db_table_hmmsearch.hmm_start,
		$db_table_hmmsearch.hmm_end,
		$db_table_blast.target,
		$db_table_blast.evalue,
		$db_table_taxa.name
		FROM $db_table_hmmsearch
		INNER JOIN $db_table_ests
			ON $db_table_hmmsearch.target = $db_table_ests.digest
		INNER JOIN $db_table_orthologs
			ON $db_table_hmmsearch.query = $db_table_orthologs.ortholog_gene_id
		INNER JOIN $db_table_blast
			ON $db_table_hmmsearch.target = $db_table_blast.query
		INNER JOIN $db_table_aaseqs
			ON $db_table_blast.target = $db_table_aaseqs.id
		INNER JOIN  $db_table_taxa
			ON $db_table_aaseqs.taxid = $db_table_taxa.id
		INNER JOIN $db_table_set_details
			ON $db_table_orthologs.setid = $db_table_set_details.id
		WHERE $db_table_set_details.id = ?
		AND $db_table_hmmsearch.taxid  = ?
		ORDER BY $db_table_hmmsearch.log_evalue ASC
		LIMIT $limit 
		OFFSET $offset
		";
	print "fetching:\n$query\n";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $setid, $specid);
	my $result = { };
	while (my $line = $sth->fetchrow_arrayref()) {
		my $start = $$line[5] - 1;
		my $length = $$line[6] - $start;
		# first key is the hmmsearch evalue, second key is the orthoid
		push( @{ $result->{$$line[0]}->{$$line[1]} }, {
			'hmmhit'       => $$line[2],
			'header'       => $$line[3],
			'sequence'     => substr($$line[4], $start, $length),
			'hmm_start'        => $$line[5],
			'hmm_end'          => $$line[6],
			'blast_hit'    => $$line[7],
			'blast_evalue' => $$line[8],
			'reftaxon'     => $$line[9],
		});
	}
	$sth->finish();
	$dbh->disconnect();
	scalar keys %$result > 0 ? return $result : return 0;
}

=head2 get_logevalue_count()

Returns a hashref as $hash->{$log_evalue} = number_of_occurences (an int)

=cut

sub get_logevalue_count {
	my $query_get_logevalues = "SELECT $db_col_log_evalue, count FROM $db_table_log_evalues";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query_get_logevalues);
	$sth = execute($sth, $db_timeout);
	my $d = $sth->fetchall_arrayref();
	$sth->finish();
	$dbh->disconnect();
	my $num_of_logevalues = { };
	foreach my $row (@$d) {
		$num_of_logevalues->{$$row[0]} = $$row[1];
	}
	return $num_of_logevalues;
}

sub get_scores_count {
	my $query_get_scores = "SELECT $db_col_score, count FROM $db_table_scores";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query_get_scores);
	$sth = execute($sth, $db_timeout);
	my $d = $sth->fetchall_arrayref();
	$sth->finish();
	$dbh->disconnect();
	my $num_of_scores = { };
	foreach my $row (@$d) {
		$num_of_scores->{$$row[0]} = $$row[1];
	}
	return $num_of_scores;
}

sub execute {
	my $sth = shift or croak "Usage: execute(STH, TIMEOUT, ARGS)\n";
	my $timeout = shift or croak "Usage: execute(STH, TIMEOUT, ARGS)\n";
	my @args = @_;
	my $slept = 0;
	until ($sth->execute(@args)) {
		carp "Warning: execution failed, retrying in $sleep_for seconds...\n";
		if ($slept > $timeout) { croak "Fatal: execution ultimately failed, failing this transaction\n" }
		sleep $sleep_for;
		$slept += $sleep_for;
	}
	return $sth;
}

=head2 get_results_for_logevalue($setid, $taxonid, $min [, $max])

Fetch results from the database that have e-value $min or are BETWEEN $min AND $max.

The function intelligently does the correct query depending on the number of arguments.

Returns a [ rows->[ (columns) ] ] arrayref.

=cut

sub get_results_for_logevalue {
	my $setid   = shift;
	my $taxid   = shift;
	my $min     = shift;
	my $max     = shift;
	# generic query
	my $query = "SELECT DISTINCT $db_table_hmmsearch.$db_col_evalue,
			$db_table_orthologs.$db_col_orthoid,
			$db_table_hmmsearch.$db_col_target,
			$db_table_ests.$db_col_header,
			$db_table_ests.$db_col_sequence,
			$db_table_hmmsearch.$db_col_hmm_start,
			$db_table_hmmsearch.$db_col_hmm_end,
			$db_table_hmmsearch.$db_col_env_start,
			$db_table_hmmsearch.$db_col_env_end,
			$db_table_blast.$db_col_target,
			$db_table_blast.$db_col_evalue,
			$db_table_taxa.$db_col_name
		FROM $db_table_log_evalues
		LEFT JOIN $db_table_hmmsearch
			ON $db_table_log_evalues.$db_col_log_evalue = $db_table_hmmsearch.$db_col_log_evalue
		LEFT JOIN $db_table_ests
			ON $db_table_hmmsearch.$db_col_target = $db_table_ests.$db_col_digest
		LEFT JOIN $db_table_orthologs
			ON $db_table_hmmsearch.$db_col_query = $db_table_orthologs.$db_col_orthoid
		LEFT JOIN $db_table_blast
			ON $db_table_hmmsearch.$db_col_target = $db_table_blast.$db_col_query
		LEFT JOIN $db_table_aaseqs
			ON $db_table_blast.$db_col_target = $db_table_aaseqs.$db_col_id
		LEFT JOIN $db_table_taxa
			ON $db_table_aaseqs.$db_col_taxid = $db_table_taxa.$db_col_id
		LEFT JOIN $db_table_set_details
			ON $db_table_orthologs.$db_col_setid = $db_table_set_details.$db_col_id
		WHERE $db_table_hmmsearch.$db_col_log_evalue IS NOT NULL
			AND $db_table_ests.$db_col_digest          IS NOT NULL
			AND $db_table_orthologs.$db_col_orthoid    IS NOT NULL
			AND $db_table_blast.$db_col_query          IS NOT NULL
			AND $db_table_aaseqs.$db_col_id            IS NOT NULL
			AND $db_table_taxa.$db_col_id              IS NOT NULL
			AND $db_table_set_details.$db_col_id       IS NOT NULL
			AND $db_table_set_details.$db_col_id       = ?
			AND $db_table_hmmsearch.$db_col_taxid      = ?";

	# modify the generic query
	# e-value range
	if ($max) { $query .= "\n			AND $db_table_hmmsearch.$db_col_log_evalue BETWEEN ? AND ?" }
	# single e-value
	else      { $query .= "\n			AND $db_table_hmmsearch.$db_col_log_evalue = ?" }

	# good for debugging
	print $query . "\n" if $debug;

	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);

	# e-value range
	if ($max) {
		$sth = execute($sth, $db_timeout, $setid, $taxid, $min, $max);
	}
	# single e-value
	else      {
		$sth = execute($sth, $db_timeout, $setid, $taxid, $min);
	} 

	# will hold the result
	my $result = { };

	while (my $line = $sth->fetchrow_arrayref()) {
		my $start = $$line[7] - 1;
		my $length = $$line[8] - $start;
		# first key is the hmmsearch evalue, second key is the orthoid
		push( @{ $result->{$$line[0]}->{$$line[1]} }, {
			'hmmhit'       => $$line[2],
			'header'       => $$line[3],
			'sequence'     => substr($$line[4], $start, $length),
			'hmm_start'    => $$line[5],
			'hmm_end'      => $$line[6],
			'env_start'    => $$line[7],
			'env_end'      => $$line[8],
			'blast_hit'    => $$line[9],
			'blast_evalue' => $$line[10],
			'reftaxon'     => $$line[11],
		});
	}
	$sth->finish();
	$dbh->disconnect();
	scalar keys %$result > 0 ? return $result : return undef;
}

sub get_results_for_score {
	my $setid   = shift;
	my $taxid   = shift;
	my $min     = shift;
	my $max     = shift;
	# generic query
	my $query = "SELECT DISTINCT $db_table_hmmsearch.$db_col_score,
			$db_table_orthologs.$db_col_orthoid,
			$db_table_hmmsearch.$db_col_target,
			$db_table_ests.$db_col_header,
			$db_table_ests.$db_col_sequence,
			$db_table_hmmsearch.$db_col_hmm_start,
			$db_table_hmmsearch.$db_col_hmm_end,
			$db_table_hmmsearch.$db_col_env_start,
			$db_table_hmmsearch.$db_col_env_end,
			$db_table_blast.$db_col_target,
			$db_table_blast.$db_col_evalue,
			$db_table_taxa.$db_col_name
		FROM $db_table_scores
		LEFT JOIN $db_table_hmmsearch
			ON $db_table_scores.$db_col_score = $db_table_hmmsearch.$db_col_score
		LEFT JOIN $db_table_ests
			ON $db_table_hmmsearch.$db_col_target = $db_table_ests.$db_col_digest
		LEFT JOIN $db_table_orthologs
			ON $db_table_hmmsearch.$db_col_query = $db_table_orthologs.$db_col_orthoid
		LEFT JOIN $db_table_blast
			ON $db_table_hmmsearch.$db_col_target = $db_table_blast.$db_col_query
		LEFT JOIN $db_table_aaseqs
			ON $db_table_blast.$db_col_target = $db_table_aaseqs.$db_col_id
		LEFT JOIN $db_table_taxa
			ON $db_table_aaseqs.$db_col_taxid = $db_table_taxa.$db_col_id
		LEFT JOIN $db_table_set_details
			ON $db_table_orthologs.$db_col_setid = $db_table_set_details.$db_col_id
		WHERE $db_table_hmmsearch.$db_col_score      IS NOT NULL
			AND $db_table_ests.$db_col_digest          IS NOT NULL
			AND $db_table_orthologs.$db_col_orthoid    IS NOT NULL
			AND $db_table_blast.$db_col_query          IS NOT NULL
			AND $db_table_aaseqs.$db_col_id            IS NOT NULL
			AND $db_table_taxa.$db_col_id              IS NOT NULL
			AND $db_table_set_details.$db_col_id       IS NOT NULL
			AND $db_table_set_details.$db_col_id       = ?
			AND $db_table_hmmsearch.$db_col_taxid      = ?";

	# modify the generic query
	# score range
	if ($max) { $query .= "\n			AND $db_table_hmmsearch.$db_col_score BETWEEN ? AND ?" }
	# single score
	else      { $query .= "\n			AND $db_table_hmmsearch.$db_col_score = ?" }

	# good for debugging
	print $query . "\n" if $debug;

	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);

	# score range
	if ($max) {
		$sth = execute($sth, $db_timeout, $setid, $taxid, $min, $max);
	}
	# single score
	else      {
		$sth = execute($sth, $db_timeout, $setid, $taxid, $min);
	} 

	# will hold the result
	my $result = { };

	while (my $line = $sth->fetchrow_arrayref()) {
		my $start = $$line[7] - 1;
		my $length = $$line[8] - $start;
		# first key is the hmmsearch score, second key is the orthoid
		push( @{ $result->{$$line[0]}->{$$line[1]} }, {
			'hmmhit'       => $$line[2],
			'header'       => $$line[3],
			'sequence'     => substr($$line[4], $start, $length),
			'hmm_start'    => $$line[5],
			'hmm_end'      => $$line[6],
			'env_start'    => $$line[7],
			'env_end'      => $$line[8],
			'blast_hit'    => $$line[9],
			'blast_evalue' => $$line[10],
			'reftaxon'     => $$line[11],
		});
	}
	$sth->finish();
	$dbh->disconnect();
	scalar keys %$result > 0 ? return $result : return undef;
}

=head2 get_hit_transcripts($species_id, $set_id)

Returns a list of transcript digests that were hit during the HMM search for
this $species_id and this $set_id. 

=cut

sub get_hit_transcripts {
	my $specid = shift(@_) or croak("Usage: get_hitlist_for(SPECIESID, SETID)");
	my $setid  = shift(@_) or croak("Usage: get_hitlist_for(SPECIESID, SETID)");
	# TODO rewrite this part using parametrized queries to protect from SQL injections?
	my $query = "SELECT DISTINCT
		$db_table_hmmsearch.target
		FROM $db_table_hmmsearch
		INNER JOIN $db_table_orthologs
			ON $db_table_hmmsearch.query = $db_table_orthologs.ortholog_gene_id
		INNER JOIN $db_table_blast
			ON $db_table_hmmsearch.target = $db_table_blast.query
		INNER JOIN $db_table_aaseqs
			ON $db_table_blast.target = $db_table_aaseqs.id
		INNER JOIN  $db_table_taxa
			ON $db_table_aaseqs.taxid = $db_table_taxa.id
		INNER JOIN $db_table_set_details
			ON $db_table_orthologs.setid = $db_table_set_details.id
		WHERE $db_table_set_details.id = $setid
		AND $db_table_hmmsearch.taxid  = $specid
	";
	my $data = &db_get($query);
	my @result;
	push(@result, ${shift(@$data)}[0]) while @$data;
	return @result;
}
	
=head2 get_reference_sequence(scalar int ID)

Fetches the amino acid sequence for ID from the database. Returns a string.

=cut

sub get_reference_sequence {
	my $id = shift @_ or croak "Usage: get_reference_sequence(ID)\n";
	my $query = "SELECT $db_col_sequence 
		FROM $db_table_aaseqs
		WHERE $db_col_id = '$id'";
	my $result = &db_get($query);
	return $result->[0]->[0];
}

sub get_transcript_for {
	my $digest = shift @_ or croak "Usage: get_transcript_for(ID)\n";
	my $query  = "SELECT $db_col_sequence
		FROM $db_table_ests
		WHERE $db_col_digest = ?";
	my $result = &db_get($query, $digest);
	return $result->[0]->[0];
}

sub get_nucleotide_transcript_for {
	my $digest = shift @_ or croak "Usage: get_transcript_for(ID)\n";
	my $query  = "SELECT $db_col_header
		FROM $db_table_ests
		WHERE $db_col_digest = ?";
	my $result = &db_get($query, $digest);
	# remove the revcomp/translate portion
	print "translated header: <$result->[0]->[0]>\n" if $debug;
	(my $original_header = $result->[0]->[0]) =~ s/ ?(\[revcomp]:)?\[translate\(\d\)\]$//;
	print "original header: <$original_header>\n" if $debug;
	$query = "SELECT $db_col_sequence
		FROM $db_table_ests
		WHERE $db_col_header = ?";
	$result = &db_get($query, $original_header);
	return $result->[0]->[0];
}

=head2 get_nuc_for_pep(scalar int ID)

Fetches the nucleotide sequence for a given amino acid sequence with id ID from the database. Returns a string.

=cut

sub get_nuc_for_pep {
	my $pepid = shift @_ or croak "Usage: get_nuc_for_pep(PEPTIDE_ID)\n";
	my $query = "SELECT $db_table_seqpairs.$db_col_ntseq 
		FROM $db_table_seqpairs
		WHERE $db_table_seqpairs.$db_col_aaseq = ?";
	print $query, "\n", $pepid, "\n";
	my $dbh = &db_dbh()
		or return undef;
	my $sth = $dbh->prepare($query);
	$sth = execute($sth, $db_timeout, $pepid);
	my $data = $sth->fetchall_arrayref();
	print Dumper($data); exit;
}

=head2 get_real_table_names(int ID, string EST_TABLE, string HMMSEARCH_TABLE, string BLAST_TABLE)

Renames the table names according to ID. Returns a list of the three table names.

=cut

sub get_real_table_names {
	my $specid = shift @_;
	my $real_table_ests      = $db_table_ests      . '_' . $specid;
	my $real_table_hmmsearch = $db_table_hmmsearch . '_' . $specid;
	my $real_table_blast     = $db_table_blast     . '_' . $specid;
	$db_table_ests        = $real_table_ests;
	$db_table_hmmsearch   = $real_table_hmmsearch;
	$db_table_blast       = $real_table_blast;
	return ($real_table_ests, $real_table_hmmsearch, $real_table_blast);
}

=head2 get_scores_list

Returns list of scores as present in the scores view

=cut

sub get_scores_list {
	my $q = "SELECT `score` FROM $db_table_scores ORDER BY `$db_table_scores`.`$db_col_score` DESC";
	return map { $_->[0] } @{db_get($q)};
}

=head2 get_hmmresult_for_score(SCORE)

Gets a list of hmmsearch hits for a given score

Arguments: scalar float 

Returns: arrayref of arrayrefs

  [
   [
    query,
    target,
    log_evalue,
    env_start,
    env_end,
    hmm_start,
    hmm_end
   ],
   [
    ...
   ]
  ]

=cut

sub get_hmmresult_for_score {
	my $score = shift;
	my $q_score_row = "SELECT 
		$db_table_hmmsearch.$db_col_query,
		$db_table_hmmsearch.$db_col_target,
		$db_table_hmmsearch.$db_col_score,
		$db_table_hmmsearch.$db_col_log_evalue,
		$db_table_hmmsearch.$db_col_env_start,
		$db_table_hmmsearch.$db_col_env_end,
		$db_table_hmmsearch.$db_col_hmm_start,
		$db_table_hmmsearch.$db_col_hmm_end
		FROM $db_table_hmmsearch
		WHERE $db_table_hmmsearch.$db_col_score = ?
		ORDER BY $db_table_hmmsearch.$db_col_log_evalue";
	my $d = db_get($q_score_row, $score);
	my $r = [];
	foreach (@$d) {
		push @$r, {
			'query'      => $_->[0],
			'target'     => $_->[1],
			'score'      => $_->[2],
			'log_evalue' => $_->[3],
			'env_start'  => $_->[4],
			'env_end'    => $_->[5],
			'hmm_start'  => $_->[6],
			'hmm_end'    => $_->[7],
		}
	}
	return $r;
}

sub get_blastresult_for_digest {
	my $digest = shift;
	my $q_blastresult = "SELECT
		$db_table_blast.$db_col_query,
		$db_table_blast.$db_col_target,
		$db_table_blast.$db_col_score,
		$db_table_blast.$db_col_log_evalue,
		$db_table_blast.$db_col_start,
		$db_table_blast.$db_col_end
		FROM $db_table_blast
		WHERE $db_table_blast.$db_col_query = ?
		ORDER BY $db_table_blast.$db_col_score";
	my $d = db_get($q_blastresult, $digest);
	my $r = [];
	foreach (@$d) {
		push @$r, {
			'query'      => $_->[0],
			'target'     => $_->[1],
			'score'      => $_->[2],
			'log_evalue' => $_->[3],
			'start'      => $_->[4],
			'end'        => $_->[5],
		}
	}
	return $r;
}

sub get_real_header {
	my $digest = shift;
	my $q = "SELECT $db_table_ests.$db_col_header
		FROM $db_table_ests
		WHERE $db_table_ests.$db_col_digest = ?
		LIMIT 1";
	print $q, "\n" if $debug;
	my $d = db_get($q, $digest);
	return $d->[0]->[0];
}

1;

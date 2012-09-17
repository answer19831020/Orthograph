#--------------------------------------------------
# This file is part of Orthograph.
# Copyright 2012 Malte Petersen <mptrsen@uni-bonn.de>
# 
# Orthograph is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
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

B<Orthograph::Blast>

=head1 DESCRIPTION

The B<Orthograph::Blast> module provides an object-oriented interface to the NCBI
blastp sequence search algorithm. It does not conform to the Guidelines of the
BioPerl package and as such does not return or handle Bioperl's Bio::Seq or
Bio::Search objects. Instead, it is designed to be a lot simpler and more
straightforward to use for applications that only want to use the NCBI BLAST+
package without the immense overhead of the entire Bioperl backend.

=head1 SYNOPSIS

  use Orthograph::Blast;

  # set up the blast program
  Orthograph::Blast->searchprog('blastp');

  # create a new blast object
  my $blastobj = Orthograph::Blast->new('/path/to/blast/database');

  # do the blastp search
  $blastobj->blastp($infile, $outfile);

=cut

package Orthograph::Blastp;
use strict;
use warnings;
use File::Basename; # basename of files
use IO::File; # object-oriented access to files
use Carp; # extended dying functions
use Data::Dumper;
my $verbose          = 0;
my $debug            = 0;
my $blastoutdir      = File::Spec->catdir('.');
my $searchprog        = 'blastp';
my $makeblastdbprog  = 'makeblastdb';
my $evalue_threshold = 10;
my $score_threshold  = 0;
my $max_hits         = 100;
my $blast_cmd;

sub new {
	my ($class, $db) = @_;

	my $self = {
		'db'       => $db,
		'query'    => undef,
		'hitcount' => undef,
	};

	bless($self, $class);
	return $self;
}

=head1 CLASS METHODS

=head3 verbose()

Sets $verbose. Defaults to 0.

=cut

sub verbose {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (scalar @_ == 1) { confess "Usage: Orthograph::Blast->verbose(1)\n" }
	$verbose = shift;
}#}}}

=head3 debug()

Sets $debug. Defaults to 0.

=cut

sub debug {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (scalar @_ == 1) { confess "Usage: Orthograph::Blast->debug(1)\n" }
	$debug = shift;
}#}}}

=head3 searchprog()

Sets the blast program. Defaults to B<blastp>.

=cut

sub searchprog {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (scalar @_ == 1) { confess "Usage: Orthograph::Blast->searchprog(COMMAND)\n" }
	$searchprog = shift;
}#}}}

=head3 set_makeblastdb()

Sets the makeblastdb program. Defaults to B<makeblastdb>.

=cut

sub set_makeblastdb {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (scalar @_ == 1) { confess "Usage: Orthograph::Blast->set_makeblastdb(COMMAND)\n" }
	$makeblastdbprog = shift;
}#}}}


=head3 outdir()

Sets the blast output directory. Defaults to 'F<.>'.

=cut

sub outdir {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (@_ == 1) { confess "Usage: Orthograph::Blast->outdir(FILENAME)\n" }
	my $blastoutdir = shift;
}#}}}

=head3 evalue_threshold()

Sets the e-value threshold to use for the blastp search. Defaults to 10.

=cut

sub evalue_threshold {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (@_ == 1) { confess "Usage: Orthograph::Blast->evalue_threshold(N)\n" }
	$evalue_threshold = shift;
}#}}}

=head3 score_threshold()

Sets the score threshold to use for the blastp search. Defaults to 10.

=cut

sub score_threshold {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (@_ == 1) { confess "Usage: Orthograph::Blast->score_threshold(N)\n" }
	$score_threshold = shift;
}#}}}

=head3 max_hits()

Sets the maximum number of hits to be returned. Defaults to 100.

=cut

sub max_hits {#{{{
	my $class = shift;
	if (ref $class) { confess "Class method used as object method\n" }
	unless (@_ == 1) { confess "Usage: Orthograph::Blastp->max_hits(N)\n" }
	$max_hits = shift;
}#}}}

=head1 OBJECT METHODS

=head3 db()

Returns the BLAST database that was selected upon creating a new object

=cut

sub db {#{{{
	my $self = shift;
	unless ($self->{'db'}) { confess "I do not have a BLAST db\n" }
	return $self->{'db'};
}#}}}

=head3 blastp()

performs the blastp search with the command line set via blast_cmdline(), using
the F<queryfile> on the blast db previously set via db() and with respect to
the e-value and score thresholds set via evalue_threshold() and
score_threshold(), respectively.

=cut

sub blastp {#{{{
	my $self = shift;
	unless (scalar @_ == 2) { confess "Usage: Orthograph::Blast->blastp(FILE, OUTFILE)\n" }
	my $queryfile = shift;
	my $outfile = shift;
	my $db = $self->db;
	# return right away if this search has been conducted before
	if (-e $outfile) {
		$self->resultfile($outfile);
		return $self;
	}
	# use outfmt 7 for comment lines
	my @blastcmd = qq($searchprog -outfmt '7 qseqid sseqid evalue bitscore' -max_target_seqs $max_hits -db $db -query $queryfile -out $outfile);

	# do the search or die
	print "\n@blastcmd\n\n"
		if $debug;
	croak "Fatal: BLAST search failed: $!\n"
		if system(@blastcmd);

	# store the resultfile path
	$self->{'resultfile'} = $outfile;
	return $self;
}#}}}

=head3 resultfile()

Sets or returns the BLAST result filename as a path.

=cut

sub resultfile {#{{{
	my $self = shift;
	if (scalar @_ == 1) {
		$self->{'resultfile'} = shift;
		return 1;
	}
	return $self->{'resultfile'};
}#}}}

=head3 hitcount()

Returns the number of BLAST hits

=cut

sub hitcount {#{{{
	my $self = shift;
	if ($self->{'hitcount'}) {
		return $self->{'hitcount'};
	}
	$self->{'hitcount'} = scalar @{$self->result};
	return $self->{'hitcount'};
}#}}}

=head3 result()

Returns the BLAST result as an array of strings, just as it is in the output file. 

=cut

sub result {#{{{
	my $self = shift;
	if ($self->{'result'}) {
		return $self->{'result'};
	}
	my $fh = IO::File->new($self->resultfile);
	$self->{'result'} = [ <$fh> ];
	# remove comment lines
	splice(@{$self->{'result'}}, 0, 5);
	pop(@{$self->{'result'}});
	$fh->close;
	return $self->{'result'};
}#}}}

=head3 blasthits_arrayref()

Returns the BLAST result as an array of arrays.

=cut

sub blasthits_arrayref {#{{{
	my $self = shift;
	if ($self->{'blasthits'}) {
		return $self->{'blasthits'};
	}
	$self->{'blasthits'} = [ ];
	foreach (@{$self->result}) {
		my @line = split(/\s+/);
		push(@{$self->{'blasthits'}}, {
			'query'  => $line[0],
			'target' => $line[1],
			'evalue' => $line[2],
			'score'  => $line[3]
		});
	}
	return $self->{'blasthits'};
}#}}}

=head1 INDEPENDENT FUNCTIONS

=head3 makeblastdb()

Create a BLAST database from a (fasta) file.

=cut

sub makeblastdb {#{{{
	croak('Usage: makeblastdb($infile, $outfile, $title)' . "\n") unless scalar(@_) == 3;
	my $infile = shift or croak('Usage: makeblastdb($infile, $outfile, $title)' . "\n");
	my $outfile = shift or croak('Usage: makeblastdb($infile, $outfile, $title)' . "\n");
	my $title = shift or croak('Usage: makeblastdb($infile, $outfile, $title)' . "\n");
	my @makeblastdbcmd = qw($makeblastdbprog -in $infile -out $outfile -input_type fasta -title $title);
}#}}}

# return true
1;

=head1 AUTHOR

Written by Malte Petersen <mptrsen@uni-bonn.de>.

=head1 COPYRIGHT

Copyright (c) 2012 by Malte Petersen. All rights reserved.

This program is free software; you may redistribute and/or modify it under the
same terms as Orthograph itself.

=cut

#!/usr/bin/perl -w

=head1 NAME

gpx2gaf.pl

=head1 SYNOPSIS

 gpx2gaf.pl --gpad /path/to/gpad_file.gpad --gpi /path/to/gpi_file.gpi --ontology /path/to/ontology_file.obo --gaf /path/for/output_file.gaf

=head1 DESCRIPTION

Converts GPAD and GPI files into a GAF 2.0 file

=head2 Input parameters

=head3 Required

=over

=item --gpad /path/to/file_name

input annotation file, GPAD format

=item --gpi /path/to/file_name

input gene product info file, GPI format

=item -ont | --ontology /path/to/file_name

input ontology file, OBO format; required to get namespace for terms

=item -o | --gaf | --output /path/to/file_name

the proposed GAF output file

=back

=head3 Optional switches

=over

=item -l || --log

Saves all errors to a log file; otherwise, errors are printed out to STDERR

=item -h || --help

This useful guide to what's going on!

=item -v || --verbose

prints various messages during the execution of the script

=back

=cut

use strict;
use warnings;
use Data::Dumper;

my $bin_dir;
my $dist_dir;

BEGIN {
	use Cwd;
	use File::Basename;
	$bin_dir = dirname(__FILE__);
	$bin_dir = Cwd::abs_path($bin_dir);
	($dist_dir = $bin_dir) =~ s/bin\/?$//;
}

use lib ($dist_dir, $bin_dir);

use GOBO::Logger;
use GOBO::AnnotationFormats qw(get_file_format get_gaf_spec get_gpi_spec get_gpad_spec transform can_transform write_errors);

my $logger;
my $metadata;

my $gaf = get_gaf_spec();
my $gpi = get_gpi_spec();
my $gpad = get_gpad_spec();

run_script(\@ARGV);

exit(0);

sub run_script {

	my $options = parse_options(@_);
	$logger->info("Parsed options. Starting script!");

	## initialise the log file if we're using one.
	if ($options->{'log'})
	{	open (my $log_fh, "> " . $options->{'log'}) or $logger->logdie("Unable to open " . $options->{gpi} . ": $!");
		$options->{log_fh} = $log_fh;
	}

	## pull in the GPI data
	read_gpi($options);

	## pull in the ontology data
	read_ontology($options);

	## process 'n' print!
	process_gpad($options);

}

sub read_gpi {
	my $opt = shift;

	open (GPI, "<" . $opt->{gpi}) or $logger->logdie("Unable to open " . $opt->{gpi} ." for reading: $!");
	while(<GPI>) {
		next unless /\w/;
		next if /^!/;
		chomp;

		## check whether it's an MGI ID or not
		my $iso;
		if ($_ !~ /^MGI/)
		{	$iso++;
		}

		my @gpi_line = split(/\t/, $_);
		unshift @gpi_line, "";

		if (! $gpi_line[ $gpi->{by_col}{gp_form_db} ] )
		{	$logger->error("No value for db gp form:\n" . @gpi_line);
		}
		if (! $gpi_line[ $gpi->{by_col}{gp_form_id} ] )
		{	$logger->error("No value for db gp form id:\n" . @gpi_line);
		}

		## does this GP have a parent GP?
		if (defined $gpi_line[ $gpi->{by_col}{parent_gp_id} ])
		{
			$metadata->{parent}{ $gpi_line[ $gpi->{by_col}{gp_form_db} ] . ":" . $gpi_line[ $gpi->{by_col}{gp_form_id} ] }{$gpi_line[ $gpi->{by_col}{parent_gp_id} ]}++;

			$metadata->{child}{$gpi_line[ $gpi->{by_col}{parent_gp_id} ]}{ $gpi_line[ $gpi->{by_col}{gp_form_db} ] . ":" . $gpi_line[ $gpi->{by_col}{gp_form_id} ] }++;

			$metadata->{all_ids}{$gpi_line[ $gpi->{by_col}{parent_gp_id} ]}++;
		}
		else
		{	if ($iso)
			{	$logger->error("No parent for isoform " . $gpi_line[ $gpi->{by_col}{gp_form_db} ] . ":" . $gpi_line[ $gpi->{by_col}{gp_form_id} ]);
			}
		}

		$metadata->{by_id}{ $gpi_line[ $gpi->{by_col}{gp_form_db} ] . ":" . $gpi_line[ $gpi->{by_col}{gp_form_id} ] } = [ @gpi_line ];

		$metadata->{all_ids}{ $gpi_line[ $gpi->{by_col}{gp_form_db} ] . ":" . $gpi_line[ $gpi->{by_col}{gp_form_id} ] }++;


	}
	close GPI;

#	$logger->error("parent hash: " . Dumper($metadata->{parent}));

	foreach my $id (keys %{$metadata->{all_ids}})
	{	if (! $metadata->{by_id}{$id} || scalar @{$metadata->{by_id}{$id}} < 1)
		{	$logger->error("No metadata for $id!");
		}
	}

	my $errs;
	## check that there is only one parent for each spliceform
	if ($metadata->{parent} && keys %{$metadata->{parent}})
	{	foreach my $i (keys %{$metadata->{parent}})
		{	my @pars = sort { $metadata->{parent}{$i}{$b} <=> $metadata->{parent}{$i}{$a} } keys %{$metadata->{parent}{$i}};
			if (scalar @pars > 1)
			{	$errs->{gpi}{too_many_parents}{$i}++;
			}
			$metadata->{parent}{$i} = $pars[0];
		}
	}

}

sub read_ontology {
	my $opt = shift;

	my $errs;
	open (FH, "<" . $opt->{ontology}) or $logger->logdie("Unable to open " . $opt->{ontology} . " for reading: $!");
	{	local $/ = "\n[";
		while(<FH>)
		{	if (/^Term]/)
			{	next if /is_obsolete: true/m;
				my $id;
				## get the id and namespace
				if (/^id: (GO:\d+)$/m)
				{	$id = $1;
					if (/^namespace: (\w+)$/m)
					{	if ($1 eq 'biological_process')
						{	$metadata->{ns_by_id}{$id} = 'P';
						}
						elsif ($1 eq 'molecular_function')
						{	$metadata->{ns_by_id}{$id} = 'F';
						}
						elsif ($1 eq 'cellular_component')
						{	$metadata->{ns_by_id}{$id} = 'C';
						}
						else
						{	push @{$errs->{ont}{invalid_ns}{$1}}, $id;
						}
					}
					else
					{	push @{$errs->{ont}{no_ns}}, $id;
					}
				}
				else
				{	push @{$errs->{ont}{no_id}}, $_;
				}
			}
		}
	}
	close(FH);

	## make sure we got SOME data!
	if (! $metadata->{ns_by_id} || (scalar keys %{$metadata->{ns_by_id}}) == 0)
	{	$logger->logdie("No ontology namespace data found: please check the ontology file and rerun the script.");
	}
	if ($errs && keys %$errs)
	{
	}
}

sub process_gpad {
	my $opt = shift;
#	my $suffix = ($opt->{gpad} =~ /gp_association\.(.+)/) ? $1 : "txt";

	my ($sec, $min, $hour, $day, $month, $year) = (localtime)[0, 1, 2, 3, 4, 5];
	my $timestamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year + 1900, $month + 1, $day, $hour, $min, $sec);

	# open all files
	open (GPAD, "<" . $opt->{gpad}) or $logger->logdie("Unable to open " . $opt->{gpad} . " for reading: $!");

	open (GAF, ">" . $opt->{gaf}) or $logger->logdie("Unable to open " . $opt->{gaf} . " for writing: $!");

	print GAF "!gaf-version: " . $gaf->{version}{major} . $gaf->{version}{minor} ."\n"
	. "!file generated at $timestamp from " . $opt->{gpad} . " by " . scr_name() . "\n"
	. "!\n";

#	my $log = "gpx2gaf_log.$suffix";
#	open (LOG, ">" . $opt->{log} ) or $logger->logdie("Unable to open " . $opt->{log} . " for writing: $!");

	my $errs;
	my $line_number = 0;
	while (<GPAD>) {
		$line_number++;
		next unless /\w/;
		if (/^!/) {
			# ignore the file format tag
			next if /^!\s*gpad-version:\s*((\d)(\.(\d))?)/;
			next if /generated at .*? by /;
			# pass all other comments through unchanged
			print GAF;
			next;
		}

		# tokenise line
		chomp;
		my @gpad_line = split(/\t/, $_);
		unshift @gpad_line, "";
		my $id = $gpad_line[ $gpad->{by_col}{gp_form_db} ] . ":" . $gpad_line[  $gpad->{by_col}{gp_form_id} ];
		my @gaf_line;

		# get the appropriate set of metadata
		# check if this is a spliceform
		my $parent;
		if ($metadata->{parent} && $metadata->{parent}{$id})
		{	$parent = $metadata->{parent}{$id};
			## do we already have this info stored?
			if (! $metadata->{by_child_id}{$id})
			{
				## find the ultimate parent for the $id
				while ( defined $metadata->{parent}{$parent} )
				{	$parent = $metadata->{parent}{$parent};
				}
			#	$logger->error("found parent $parent for $id!");
				if ($metadata->{by_id}{$parent} && scalar @{$metadata->{by_id}{$parent}} < 1)
				{	$logger->error("Don't have much metadata for $parent! :(");
				}

				## check that we have the metadata for the parent
				if (! $metadata->{by_id}{$parent})
				{	#print LOG "$gpad ($line_number): metadata not found for $id\n";
					$errs->{gpi}{no_metadata}{$parent}++;
					$logger->error("$line_number: metadata not found for parent $parent of $id");
					# we'll have to just use the metadata from the spliceform
				}
				else
				{	## otherwise, store the metadata for ease of access
					## db_object_type should be preserved
					## id goes to gp_object_form_id
					$metadata->{by_child_id}{$id} = [ @{$metadata->{by_id}{ $parent }} ];
				}
			}
		}

		## gather the data to put into @new_line
		foreach my $col (keys %{$gaf->{by_col}})
		{	## is this GPAD data?
			if ($gpad->{by_col}{ $col })
			{	#$logger->info("looking at $col: it's GPAD info") if $parent;
				## copy the data from the gpad line
				$gaf_line[ $gaf->{by_col}{$col} ] = $gpad_line[ $gpad->{by_col}{$col} ] || "";
			}
			elsif ($gpi->{by_col}{ $col })
			{	## copy the data from metadata->{by_id}{$id}[ $gpi->{by_col}{$col} ]
				$gaf_line[ $gaf->{by_col}{$col} ] =
				## if this is a spliceform
				$metadata->{by_child_id}{$id}[ $gpi->{by_col}{$col} ] ||
				## this is just a standard thing
				$metadata->{by_id}{$id}[ $gpi->{by_col}{$col} ] ||
				## no value
				"";
			}
			elsif (can_transform( $col ))
			{	## data needs to be transformed in some way
				$gaf_line[ $gaf->{by_col}{$col} ] = transform($col,
					id => $id,
					errs => \$errs,
					logger => $logger,
					metadata => $metadata,
					gpad_data => [ @gpad_line ],
					ontology => $metadata->{ns_by_id},
					parent => ($parent || ""),
				) || '';
				if ($parent && ($col =~ /gp_form/))
				{	$logger->error("looking at $col for $id, parent $parent; result: " . ( $gaf_line[ $gaf->{by_col}{$col} ] || "blank" ) );
				}
			}
			else
			{	$logger->error("Don't know what to do with $col data!!");
				$gaf_line[ $gaf->{by_col}{$col} ] = '';
			}
		}

		shift @gaf_line;
		if ($errs->{line_err})
		{	## terrible, unrecoverable error
			delete $errs->{line_err};
		}
		else
		{
			print GAF join("\t", @gaf_line) . "\n";
		}
#		$logger->error("gaf line: " . join(", ", @gaf_line));
	}

	if ($errs)
	{	write_errors( errs => $errs, options => $opt, logger => $logger );
	}

	# all done
	close GPAD;
	close GAF;
	if ($opt->{'log'})
	{	close $opt->{log_fh};
	}
}


# parse the options from the command line
sub parse_options {
	my ($args) = @_;
	my $errs;
	my $opt;
	while (@$args && $args->[0] =~ /^\-/) {
		my $o = shift @$args;
		if ($o eq '--gpad') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{gpad} = shift @$args;
			}
		}
		elsif ($o eq '--gpi') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{gpi} = shift @$args;
			}
		}
		elsif ($o eq '-o' || $o eq '--output' || $o eq '--gaf') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{gaf} = shift @$args;
			}
		}
		elsif ($o eq '-ont' || $o eq '--ontology') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{ontology} = shift @$args;
			}
		}
		elsif ($o eq '-l' || $o eq '--log') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{log} = shift @$args;
			}
		}
		elsif ($o eq '-h' || $o eq '--help') {
			system("perldoc", $0);
			exit(0);
		}
		elsif ($o eq '-v' || $o eq '--verbose') {
			$opt->{verbose} = 1;
		}
		elsif ($o eq '--galaxy') {
			$opt->{galaxy} = 1;
		}
		else {
			push @$errs, "Ignored nonexistent option $o";
		}
	}

	return check_options($opt, $errs);
}


# process the input params
sub check_options {
	my ($opt, $errs) = @_;

	if (!$opt)
	{	GOBO::Logger::init_with_config( 'standard' );
		$logger = GOBO::Logger::get_logger();
		$logger->logdie("Error: please ensure you have specified GPAD and GPI input files and an output file.\nThe help documentation can be accessed using the command\n\t" . scr_name() . " --help");
	}

	if (! $opt->{verbose})
	{	$opt->{verbose} = $ENV{GO_VERBOSE} || 0;
	}

	if ($opt->{galaxy})
	{	GOBO::Logger::init_with_config( 'galaxy' );
		$logger = GOBO::Logger::get_logger();
	}
	elsif ($opt->{verbose} || $ENV{DEBUG})
	{	GOBO::Logger::init_with_config( 'verbose' );
		$logger = GOBO::Logger::get_logger();
	}
	else
	{	GOBO::Logger::init_with_config( 'standard' );
		$logger = GOBO::Logger::get_logger();
	}

	$logger->debug("args: " . Dumper($opt));

	if ($errs && @$errs)
	{	foreach (@$errs)
		{	$logger->error($_);
		}
	}
	undef $errs;

	if ($opt->{galaxy} && ! $opt->{'log'})
	{	## we need a log file if we're in Galaxy mode
		push @$errs, "specify a log file if using the script in Galaxy mode";
	}

	my $h = {
		gpad => $gpad,
		gpi => $gpi,
	};
	foreach my $g qw(gpad gpi)
	{	if (!$opt->{$g})
		{	## no input
			push @$errs, "specify a " . uc($g) . " format input file using --" . $g . " /path/to/file";
		}
		else
		{	## check the file is ok
			if (! -e $opt->{$g})
			{	push @$errs, "the file " . $opt->{$g} . " could not be found.";
			}
			elsif (! -r $opt->{$g} || -z $opt->{$g})
			{	push @$errs, "the file " . $opt->{$g} . " could not be read.";
			}
			else
			{	my ($format, $major, $minor) = get_file_format($opt->{$g});
				if (! defined($format) || $format ne $g || $major ne $h->{$g}{version}{major} || $minor ne $h->{$g}{version}{minor})
				{	push @$errs, $opt->{$g} . " is not in $g v" . $h->{$g}{version}{major} . $h->{$g}{version}{minor} . " format!";
				}
			}
		}
	}

	if (! $opt->{ontology})
	{	push @$errs, "specify an ontology file using --ontology /path/to/file";
	}
	elsif (! -e $opt->{ontology})
	{	push @$errs, "the file " . $opt->{ontology} . " could not be found.";
	}
	elsif (! -r $opt->{ontology} || -z $opt->{ontology})
	{	push @$errs, "the file " . $opt->{ontology} . " could not be read.";
	}

	if (! $opt->{gaf})
	{	push @$errs, "specify an output (GAF) file using -o /path/to/file";
	}
	elsif ($opt->{gaf} !~ /\.gaf$/i && ! $opt->{galaxy})
	{	## make sure the file ending is 'gaf'
		$opt->{gaf} .= '.gaf';
		$logger->info("Appending '.gaf' to output file name");
	}

	if (! $opt->{log})
	{	#$logger->warn("Sending error messages to STDOUT");
		#push @$errs, "specify an log file using -l /path/to/file";
	}

	## end processing
	if ($errs && @$errs)
	{	$logger->logdie("Please correct the following parameters to run the script:\n" . ( join("\n", map { " - " . $_ } @$errs ) ) . "\nThe help documentation can be accessed with the command\n\t" . scr_name() . " --help");
	}

	return $opt;
}

## script name, minus path
sub scr_name {
	my $n = $0;
	$n =~ s/^.*\///;
	return $n;
}

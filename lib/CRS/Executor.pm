package CRS::Executor;

=head1 NAME

CRS::Executor - Library for executing Tracker XML Jobfiles

=head1 VERSION

Version 1.0rc1

=head1 SYNOPSIS

Generic usage:

    use CRS::Executor;
    my $executor = new CRS::Executor($jobxml);
    $ex->execute();

=head1 DESCRIPTION

The CRS tracker uses a well-defined XML schema to describe commands that shall be executed by workers.
This library "unpacks" those XML job files and actually executes the commands, thereby handling things
like managing input and output files and directories, correct encoding etc.

=head1 METHODS

=head2 new ($jobfile)

Create a new instance, giving it an XML jobfile. The parameter can be either a string containing XML or
a string containing the absolute full path to an XML file.

=head2 execute ($jobtype)

Actually execute the commands described in the XML jobfile. The optional jobtype argument can be used to
execute other tasks than the default jobtype of 'encoding'.

Returns undef on error (or dies on fatal error), returns 1 if all tasks were executed successfully.

=head2 getOutput ()

Returns the output of the executed commands together with informational output from the library as array.

=cut

use strict;
use warnings;
use charnames ':full';

use File::Spec;
use File::Which qw(which);
use XML::Simple qw(:strict);
use Encode;

use constant FILE_OK => 0;

sub new {
	shift;
	my $jobxml = shift;
	my $self;

	#### CHECK: utf8::encode($jobxml);
	$self->{jobxml} = $jobxml;
	$self->{job} = load_job($jobxml);

	# do not create instance if jobxml is faulty
	return unless defined $self->{job};

	$self->{locenc} = 'ascii';
	$self->{locenc} = `locale charmap`;
	
	$self->{outfilemap} = {};
	$self->{output} = [];

	bless $self;
	return $self;
}

sub print {
	my ($self, $text) = @_;
	push @{$self->{output}}, $text;
	print "$text\n";
}

# static method, convert Unicode to ASCII, as callback from Encode
sub asciify {
    my ($ord) = @_;

    # is ASCII -> change nothing
    if ($ord < 128) {
        return chr($ord);
    }
    my $name = charnames::viacode($ord);
    my ($main, $with) = $name =~ m{^(.+)\sWITH\s(.*)}o;
    if (defined $with) {
        if (($with eq 'DIAERESIS') and ($main =~ m{\b[aou]\b}oi)) {
            return chr(charnames::vianame($main)) ."e";
        }
        return chr(charnames::vianame($main));
    }
    return "ss" if ($name eq 'LATIN SMALL LETTER SHARP S');
    return "?";
}

# static method, load job XML into object
sub load_job {

    my $jobfile = shift;
    die 'You need to supply a job!' unless $jobfile;

    my $job = XMLin(
        $jobfile,
        ForceArray => [
            'option',
            'task',
            'tasks',
        ],
        KeyAttr => ['id'],
    );
    return $job;
}

# static method, escape/remove shell quotes
sub replacequotes {
    my ($toquote) = @_;

    # contains quotes
    if ($^O eq 'linux') {
        # escape them on Linux
        $toquote =~ s{"}{\\"}og;
    } else {
        # strip them
        $toquote =~ s{"}{}og;
    }

    return $toquote;
}

# search a file
sub check_file {
	my ($self, $name, $type) = @_;

	# executable lookup
	if ($type eq 'exe') {
		return ($name, FILE_OK) if -x $name;
		my $path = which $name;
		die "Executable $name cannot be found!" unless defined($path);
		die "Executable $name is not executable!" unless -x $path;
		return ($name, FILE_OK);
	}

	# all other files must be given with absolute paths:
	if (not File::Spec->file_name_is_absolute($name)) {
		 die "Non-absolute filename given: '$name'!";
	}

	# input and config files must exist
	if ($type eq 'in' or $type eq 'cfg') {
		return ($name, FILE_OK) if -r $name;

		# maybe it is a file that is produced during this execution?
		if (defined($self->{outfilemap}->{$name})) {
			return ($self->{outfilemap}->{$name}, FILE_OK);
		}
		# try harder to find: asciify filename
		$name = encode('ascii', $name, \&asciify);
		return ($name, FILE_OK) if -r $name;

		die "Fatal: File $name is missing!";
	}

	# output files must not exist. if they do, they are deleted and deletion is checked
	if ($type eq 'out') {
		if (-e $name) {
			$self->print ("Output file exists: '$name', deleting file.");
			unlink $name;
			die "Cannot delete '$name'!" if -e $name;
		}
		# check that the directory of the output file exists and is writable. if it
		# does not exist, try to create it.
		my(undef,$outputdir,undef) = File::Spec->splitpath($name);
		if (not -d $outputdir) {
			$self->print ("Output path '$outputdir' does not exist, trying to create");
			qx ( mkdir -p $outputdir );
			die "Cannot create directory '$outputdir'!" if (not -d $outputdir);
		}
		die "Output path '$outputdir' is not writable!" unless (-w $outputdir or -k $outputdir);

		# store real output filename, return unique temp filename instead
		if (defined($self->{outfilemap}->{$name})) {
			return ($self->{outfilemap}->{$name}, FILE_OK);
		} else {
			my $safety = 10;
			do {
				my $tempname = $name . '.' . int(rand(32767));
				$self->{outfilemap}->{$name} = $tempname;
				return ($tempname, FILE_OK) unless -e $tempname;
			} while ($safety--);
			die "Unable to produce random tempname!";
		}
	}

	# do not allow unknown filetypes
	die "Unknown file type in jobfile: $type";
}

# create command 
sub parse_cmd {
	my ($self, $options) = @_;

	my $cmd = '';
	my $filerr = 0;
	my @outfiles;

	CONSTRUCT: foreach my $option (@$options) {
		my $cmdpart = '';
		if (ref \$option ne 'SCALAR') {
			if ($option->{filetype}) {
				# check locations and re-write file name 
				my $type = $option->{filetype};
				my $error;
				($cmdpart, $error) = $self->check_file($option->{content}, $type);

				# remember file problems
				$filerr = $error if $error;
			} else {
				# check for quoting option
				if (defined($option->{'quoted'}) && $option->{'quoted'} eq 'no') {
					$cmd .= ' ' . $option->{content} . ' ';
				} else {
					# just copy value
					$cmdpart = $option->{content};
				}
			}
		} else {
			$cmdpart = $option
		}
		next unless defined($cmdpart);

		if ($cmdpart =~ m{[ \[\]\(\)]}o) {
			# escape or remove existing quotes
			$cmdpart = replacequotes($cmdpart) if $cmdpart =~ m{"}o;
			# replace $ in cmds
			$cmdpart =~ s/\$/\\\$/g;
			# quote everything with regular double quotes
			if ($cmd =~ m{=$}o) {
				$cmd .= '"'. $cmdpart .'"';
			} else {
				$cmd .= ' "'. $cmdpart .'"';
			}
		} else {
			$cmdpart = replacequotes($cmdpart) if $cmdpart =~ m{"}o;
			if ($cmd =~ m{=$}o) {
				$cmd .= $cmdpart;
			} else {
				$cmd .= ' '. $cmdpart;
			}
		}
	}

	$cmd =~ s{^ }{}o;
	return $cmd;
}

sub run_cmd {
	my ($self, $cmd, $cmdencoding) = @_;

	# set encoding on STDOUT so program output can be re-printed without errors
	binmode STDOUT, ":encoding($self->{locenc})";

	$self->print ("running: \n$cmd\n\n");
	# The encoding in which the command is run is configurable, e.g. you want 
	# utf8 encoded metadata as parameter to FFmpeg also on a non-utf8 shell.
	$cmdencoding = 'UTF-8' unless defined($cmdencoding);
	$cmd = encode($cmdencoding, $cmd);

	my $handle;
	open ($handle, '-|', $cmd . ' 2>&1') or die "Cannot execute command";
	while (<$handle>) {
		my $line = decode($cmdencoding, $_);
		print $line;
		chomp $line;
		push @{$self->{output}}, $line;
	}
	close ($handle);

	# reset encoding layer
	binmode STDOUT;

	# check return code
	if ($?) {
		$self->print ("Task exited with code $?");
		return 0;
	}
	return 1;
}

sub task_loop {
	my $self = shift;

	my @tasks = ( ) ;
	foreach(@{$self->{job}->{tasks}}) {
		foreach(@{$_->{task}}) {
			push @tasks, $_ if $_->{type} eq $self->{filter};
		}
	}

	my $num_tasks = scalar @tasks;
	TASK: for (my $task_id = 0; $task_id < $num_tasks; ++$task_id) {
		next TASK if (defined($self->{filter}) and $tasks[$task_id]->{type} ne $self->{filter});

		# parse XML and print cmd
		my $cmd = $self->parse_cmd($tasks[$task_id]->{option});
		$self->print ("now executing task " . ($task_id + 1) . " of $num_tasks");

		my $successful = $self->run_cmd($cmd, $tasks[$task_id]->{encoding});

		#check output files for existence if command claimed to be successfull
		if ($successful) {
			foreach (keys %{$self->{outfilemap}}) {
				next if -e $self->{outfilemap}->{$_};
				$successful = 0;
				$self->print ("output file missing: $_");
			}
		}

		#rename output files to real filenames after successful execution, delete them otherwise
		foreach (keys %{$self->{outfilemap}}) {
			my ($src, $dest) = ($self->{outfilemap}->{$_},$_);
			if ($successful) {
				$self->print ("renaming '$src' to '$dest'");
				rename ($src, $dest);
				delete ($self->{outfilemap}->{$_});
			} else {
				$self->print ("deleting '$src'");
				unlink $src;
			}
		}

		return unless $successful;
	}
	return 1;
}

sub execute {
	my ($self, $filter) = @_;

	$self->{filter} = $filter if defined($filter);
	$self->{filter} = 'encoding' unless defined($filter);
	return $self->task_loop();
}

sub getOutput {
	my $self = shift;
	return @{$self->{output}};
}

1;

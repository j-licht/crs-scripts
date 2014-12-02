#!/usr/bin/perl -W

require CRS::Auphonic;
require C3TT::Client;
require boolean;
use File::Basename qw(dirname);
use Data::Dumper;

my ($secret, $token) = ($ENV{'CRS_SECRET'}, $ENV{'CRS_TOKEN'});

if (!defined($token)) {
	# print usage
	print STDERR "Too few information given!\n\n";
	print STDERR "set environment variables CRS_SECRET and CRS_TOKEN\n\n";
	exit 1;
}

my $filter = {};
if (defined($ENV{'CRS_PROFILE'})) {
	$filter->{'EncodingProfile.Slug'} = $ENV{'CRS_PROFILE'};
}

my $tracker = C3TT::Client->new();
my $ticket = $tracker->assignNextUnassignedForState('encoding','postencoding', $filter);

if (!defined($ticket) || ref($ticket) eq 'boolean' || $ticket->{id} <= 0) {
	print "currently no tickets for postencoding\n";
} else {
	my $tid = $ticket->{id};
	my $props = $tracker->getTicketProperties($tid);
	my $vid = $props->{'Fahrplan.ID'};
	print "got ticket # $tid for event $vid\n";

	my $auphonicToken = $props->{'Processing.Auphonic.Token'};
	my $auphonicPreset = $props->{'Processing.Auphonic.Preset'};
	my $audio1 = $props->{'Processing.Path.Tmp'}.'/'.$vid.'-'.$props->{'EncodingProfile.Slug'}.'-audio1.ts';
	my $auphonic = CRS::Auphonic->new($auphonicToken);

	print "Starting production for audio track 1\n";
	my $auphonic_1 = $auphonic->startProduction($auphonicPreset, $audio1, $props->{'Project.Slug'}.'-'.$vid.'-audio1') or die $!;

	if (!defined($auphonic_1)) {
		print STDERR "Starting production for audio track 1 failed!\n";
		$tracker->setTicketFailed($tid, "Starting production for audio track 1 failed!");
		die;
	}
	
	my $uuid1 = $auphonic_1->getUUID();
	print "Started production for audio track 1 as '$uuid1'\n";
	my %props_new = (
		'Processing.Auphonic.ProductionID1' => $uuid1,
	);

	# check second audio track
	my $lang = $props->{'Record.Language'};
	if ($lang =~ /^..-../) {
		$audio2 = $props->{'Processing.Path.Tmp'}.'/'.$vid.'-'.$props->{'EncodingProfile.Slug'}.'-audio2.ts';
		print "Starting production for audio track 2\n";
		my $auphonic_2 = $auphonic->startProduction($auphonicPreset, $audio2, $props->{'Project.Slug'}.'-'.$vid.'-audio2') or die $!;
		if (!defined($auphonic_2)) {
			$tracker->setTicketFailed($tid, "Starting production for audio track 2 failed!");
			die;
		}
		my $uuid2 = $auphonic_2->getUUID();
		print "Started production for audio track 2 as '$uuid2'\n";
		$props_new{'Processing.Auphonic.ProductionID2'} = $uuid2;
	}
	$tracker->setTicketProperties($tid, \%props_new);
	# $tracker->setTicketDone($tid, 'Auphonic production started'); # TODO optional machen fuer anderes pipeline layout?
}

print "querying for assigned ticket in state postencoding ...\n";
my $tickets = $tracker->getAssignedForState('encoding', 'postencoding', $filter);

if (!($tickets) || 0 == scalar(@$tickets)) {
	print "no assigned tickets currently postencoding. exiting...\n";
	exit 0;
}

print "found " . scalar(@$tickets) ." tickets\n";
foreach (@$tickets) {
	my $ticket = $_;
	my $tid = $ticket->{id};
	my $props = $tracker->getTicketProperties($tid);
	my $vid = $props->{'Fahrplan.ID'};
	print "got ticket # $tid for event $vid\n";

	my $auphonicToken = $props->{'Processing.Auphonic.Token'};
	my $uuid1 = $props->{'Processing.Auphonic.ProductionID1'};
	my $uuid2 = $props->{'Processing.Auphonic.ProductionID2'};

	# poll production states
	my $a1 = CRS::Auphonic->new($auphonicToken, $uuid1);
	if (!$a1->isFinished()) {
		print "production $uuid1 not done yet.. skipping\n";
		next;
	}
	my $a2 = undef;
	if (defined($uuid2)) {
		$a2 = CRS::Auphonic->new($auphonicToken, $uuid2);
		if (!$a2->isFinished()) {
			print "production $uuid2 not done yet.. skipping\n";
			next;
		}
	}

	# download audio files
	my $dest1 = $props->{'Processing.Path.Tmp'}.'/'.$vid.'-'.$props->{'EncodingProfile.Slug'}.'-audio1-auphonic.m4a';
	my $dest2 = $props->{'Processing.Path.Tmp'}.'/'.$vid.'-'.$props->{'EncodingProfile.Slug'}.'-audio2-auphonic.m4a';

	print "downloading audio track 1 from Auphonic... to $dest1\n";
	if (!$a1->downloadResult($dest1)) {
		$tracker->setTicketFailed($tid, 'download of audio track 1 from auphonic failed!');
	}
	if (defined($uuid2)) {
		print "downloading audio track 2 from Auphonic... to $dest2\n";
		if (!$a2->downloadResult($dest2)) {
			$tracker->setTicketFailed($tid, 'download of audio track 2 from auphonic failed!');
		}
	}

	# remux via encoding profile job of type "remux"
	print "remuxing audio tracks...\n";
	my $jobfile = $tracker->getJobFile($tid);
	my $jobfilePath = $props->{'Processing.Path.Tmp'}.'/job-'.$tid.'.xml';
	open(my $file, ">", $jobfilePath) or die $!;
	print $file "$jobfile";
	close $file;

	my $perlPath = $props->{'Processing.Path.Exmljob'};
	if (!defined($perlPath) || $perlPath eq '') {
		print STDERR "Processing.Path.Exmljob is missing!";
		sleep 5;
		die;
	}

	my $perlDir = dirname($perlPath);
	chdir $perlDir;
	$output = qx ( perl "$perlPath" -t remux "$jobfilePath" );
	if ($?) {
		$tracker->setTicketFailed($tid, "remuxing failed! Status: $? Output: '$output'");
		die;
	}

	$tracker->setTicketDone($tid);
	print "sleeping a while...\n";
	sleep 5;
}


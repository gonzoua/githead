#!/usr/bin/env perl
# Copyright (C) 2011 by Oleksandr Tymoshenko. All rights reserved.

use strict;
use warnings;
use Data::Dumper;
use POSIX;
use Tie::Array::Sorted;
use YAML;
use Time::Local;

use File::Temp qw/ :mktemp  /;
use File::Path;
use File::Spec;
use File::Basename;
use Getopt::Std;
$Getopt::Std::STANDARD_HELP_VERSION = 1;
$main::VERSION = "0.1";

my $tmp_dir =  File::Spec->tmpdir;
my $rlog_tmp_file = mktemp("$tmp_dir/githead.rlog.XXXXX");
my $patchsets_tmp_file = mktemp("$tmp_dir/githead.patchsets.XXXXX");

my %opts;
getopts('d:C:o:s:xh?', \%opts);

if (defined($opts{h}) || defined($opts{'?'})) {
    usage();
    exit(0);
}

my $CVSRoot;
if (defined($opts{d})) {
    $CVSRoot = $opts{d};
}
elsif(defined($ENV{CVSROOT})) {
    $CVSRoot = $ENV{CVSROOT};
}
my $module = $ARGV[0];
if (!defined($module)) {
    print STDERR "module name is not provided\n";
    usage();
    exit(1);
}

if (!defined($CVSRoot)) {
    print STDERR "CVSROOT is not provided\n";
    usage();
    exit(1);
}

my $normalized_cvsroot = $CVSRoot;
$normalized_cvsroot =~ s/[^a-z0-9]/-/ig;

my $git_dir = "$module.git";
$git_dir = $opts{C} if(defined($opts{C}));
my $upstreamBranch = '';
$upstreamBranch = "-o " . $opts{o} if(defined($opts{o}));
my $stateFilesDir = $ENV{"HOME"} . "/.githead";
my $stateFile = "$stateFilesDir/$module-$normalized_cvsroot.githead.state";
if (defined($opts{s})) {
    $stateFilesDir = dirname(defined($opts{s}));
}

if (! -d $stateFilesDir) {
    # It will "croak" in case of failure
    mkpath($stateFilesDir);
}

my $module_path;
if ($CVSRoot =~ /(\/.*$)/) {
    $module_path = "$1/$module";
    # cleanup 
    $module_path =~ s@//@/@g;
}

if (!defined($module_path)) {
    print STDERR "Can't obtain module path from CVSROOT";
    exit(1);
}

my @commits;
tie @commits, 'Tie::Array::Sorted', sub {$_[0]->{'timet'} <=> $_[1]->{'timet'}};
my $latest_base_commit_ref;

my $timespan = 10*60;
my @known_commits;

if (!defined($opts{x})) {
    if (open F, "<$stateFile") {
        undef local $/;
        @known_commits = Load(<F>);
        $latest_base_commit_ref = $known_commits[0] if(@known_commits);
    }
}

my $rlog_timestamp = POSIX::mktime(localtime);
my $dates = '';
if (@known_commits) {
    my $last_base_timet = $known_commits[0]->{timet};
    my $rlog_start = strftime("%Y/%m/%d %H:%M:%S", localtime($last_base_timet - $timespan));
    print "Fetch logs since $rlog_start\n";
    $dates = "-d '$rlog_start<'";
}

my $cmd = "cvs -d$CVSRoot rlog $dates -N -S $module > $rlog_tmp_file";
system($cmd);
if ($?) {
    print STDERR "Failed to perform cvs rlog\n";
    print "Command: $cmd\n";
    unlink($rlog_tmp_file);
    exit(1);
}

open RLOG, "<$rlog_tmp_file";
my $files =0;
while(1) {
    my $file = readFile(\*RLOG);
    last unless(defined($file));
    $files++;
}

my $idx = 0;
my $patchset = 1;

# 10 minutes timespan should be enough
my $have_base_commit = 0;
# find base for continue
while (($idx < @commits) && defined($latest_base_commit_ref)) {
    my $base_commit_ref = $commits[$idx];
    $idx++;   
    if (($base_commit_ref->{filename} eq $latest_base_commit_ref->{filename})
          && ($base_commit_ref->{revision} eq $latest_base_commit_ref->{revision})) {
        $have_base_commit = 1;
        last;
    }
}

$idx = 0 if (!$have_base_commit);
my $last_base_commit_idx = -1;

open CVSPS, "> $patchsets_tmp_file";
while ($idx < @commits) {
    my %known_files = ();
    my @patchset_commits;
    my $base_commit_ref = $commits[$idx];

    if ($base_commit_ref->{patchset}) {
        $idx++;
        next;
    }

    last if ($base_commit_ref->{timet} >= ($rlog_timestamp - 2*$timespan));

    $base_commit_ref->{patchset} = $patchset;
    push @patchset_commits, $base_commit_ref;
    $known_files{$base_commit_ref->{filename}} = 1;
    my $i = $idx + 1;
    my $last_possible_commit = $base_commit_ref->{timet} + $timespan;
    $last_base_commit_idx = $idx;
    while (($i < @commits) && ($commits[$i]->{timet} <= $last_possible_commit)) {
        my $ref = $commits[$i];
        $i++;
        # File can't be modified more then once in a patchset
        last if ($known_files{$ref->{filename}});
        next if ($ref->{patchset});
        next unless($ref->{author} eq $base_commit_ref->{author});
        next unless($ref->{comment} eq $base_commit_ref->{comment});
        $known_files{$ref->{filename}} = 1;
        $ref->{patchset} = $patchset;
        push @patchset_commits, $ref;
    }

    print CVSPS gen_patchset($patchset, \@patchset_commits);

    $patchset++;
    $idx++;
}

close CVSPS;

# there were no patchsets
if ($patchset == 1) {
    print STDERR "No new patchsets\n";
    unlink($patchsets_tmp_file);
    unlink($rlog_tmp_file);
    exit(0);
}

# feed generated patchsets to git-cvsimport
system("git cvsimport -k -P $patchsets_tmp_file -C $git_dir -v -d$CVSRoot $upstreamBranch  $module");
if ($?) {
    print STDERR "git cvsimport failed\n";
    unlink($patchsets_tmp_file);
    unlink($rlog_tmp_file);
    exit(1);
}

if ($last_base_commit_idx >= 0) {
    $idx = $last_base_commit_idx;
    my @latest_used_commits;
    while ($idx < @commits) {
        # first commit - the pase of latest patchset
        my $ref = $commits[$idx];
        push @latest_used_commits, $ref if ($ref->{patchset});
        $idx++;
    }

    if (open STATE, "> $stateFile") {
        print STATE Dump(@latest_used_commits);
        close STATE;
    }
    else
    {
        # Just generate some temporary file and save state there
        my $rescue_state_file = mktemp("$tmp_dir/githead.state.XXXXX");
        open STATE, "> $rescue_state_file";
        print STATE Dump(@latest_used_commits);
        close STATE;
        print STDERR "Can't save state to $stateFile\n";
        print STDERR "Saved latest state to $rescue_state_file";
    }
}

# Cleanup
unlink($patchsets_tmp_file);
unlink($rlog_tmp_file);

#
# Subroutines
#
sub tryReadRevision
{
    my $rlog = shift;
    my $rev_ref = {};
    my $line = <$rlog>;
    return unless(defined($line));
    chomp $line;
    return undef unless(defined($line));
    # re-read line if it's separator
    $line = <$rlog> if ($line eq '-'x28);
    chomp $line;
    if($line =~ /^revision (\d+(?:\.\d+)+)$/) { # OK, it looks like revision
        $rev_ref->{revision} = $1;
    }
    else {
        return;
    }

    my $comment = '';
    while($line = <$rlog>) {
        chomp $line;
        if($line =~ /date: (\d+)\/(\d+)\/(\d+) (\d+):(\d+):(\d+);  author: (\w+);  state: (.*);/) {
            $rev_ref->{timet} = timegm($6, $5, $4, $3, $2 - 1, $1 - 1900);
            $rev_ref->{date} = "$1/$2/$3 $4:$5:$6";
            $rev_ref->{author} = $7;
            $rev_ref->{state} = $8;
        }
        elsif($line =~ /^branches: .*/) {
            # Just skip it
        }
        elsif($line eq '='x77) {
            last;
        }
        elsif($line eq '-'x28)  {
            last;
        }
        else {
            $comment .= $line . "\n";
        }
    }
    chomp $comment;
    $rev_ref->{comment} = $comment;
    return $rev_ref;
}

sub readCommits
{
    my $rlog = shift;
    my $filename = shift;
    my $branch = shift;
    my $revisions = [];

    my $line;
    while($line = <$rlog>) {
        chomp $line;
        last if ($line eq '-'x28);
        last if ($line eq '='x77);
    }
    
    return $revisions if ($line eq '='x77);

    last unless(defined($line));
    $branch = '1' if (!defined($branch) || ($branch eq ''));

    while(1) {
        my $rev = tryReadRevision($rlog);
        last if(!defined($rev));
        $rev->{filename} = $filename;
        # Take into account only HEAD commits and vendor branches
        if($rev->{revision} =~ /^$branch\.\d+$/) {
            push @{$revisions}, $rev;
            push @commits, $rev if($rev->{revision} =~ /^$branch\.\d+$/);
        }
    }

    return $revisions;
}

sub readFile
{
    my $rlog = shift;
    my $file = {};
    my $lastFile = 1;
    my $branch;
    while(my $line = <$rlog>) {
        chomp $line;
        if($line =~ /^RCS file: (.*),v/) {
            my $name = $1;
            $name =~ s/$module_path\/?//;
            # check for Attic 
            $name =~ s@Attic/@@;
            $file->{name} = $name;
        }
        elsif($line =~ /^branch: ?(.*)$/) {
            $branch = $1;
        }
        elsif($line =~ /^description:.*$/) {
            my $revisions = readCommits($rlog, $file->{name}, $branch);
            $branch = undef;
            $lastFile = 0;
            last;
        }
    }


    if ($lastFile) {
        return;
    }
    else {
        return $file;
    }
}

sub gen_patchset
{
    my $ps = shift;
    my $commits_ref = shift;
    my $base = $commits_ref->[0];
    my $comment = $base->{comment};
    my $date = $base->{date};
    my $author = $base->{author};
    my $ps_text = '';
    $ps_text .= "-"x21;
    $ps_text .= "\n";
    $ps_text .= "PatchSet $ps\n";
    $ps_text .= "Date: $date\n";
    $ps_text .= "Author: $author\n";
    $ps_text .= "Branch: HEAD\n";
    $ps_text .= "Tag: (none)\n";
    $ps_text .= "Log:\n";
    $ps_text .= "$comment\n";
    $ps_text .= "Members:\n";
    foreach my $c (@{$commits_ref}) {
        my $rev = $c->{revision};
        my $state = $c->{state};
        my $prev_rev;
        if (($rev eq '1.1') || ($rev eq '1.1.1.1')) {
            $prev_rev = 'INITIAL';
        }
        else {
            $rev =~ m/(.*)\.(\d+)$/;
            $prev_rev = "$1." . ($2 - 1);
        }
        $rev .= '(DEAD)' if ($state eq 'dead');
        $ps_text .= "  " . $c->{filename} . ":$prev_rev->$rev\n";
    }

    return $ps_text;
}

sub usage
{
    print STDERR "Usage: githead.pl [-o branch] [-C gitdir] [-d CVSROOT] [-s statefile] [-x] module\n";
    print STDERR "\t-C gitdir\ttarget dir, default: module.git\n";
    print STDERR "\t-d CVS ROOT\tCVS root, default env. CVSROOT variable\n";
    print STDERR "\t-h, -?\t\tprint this message\n";
    print STDERR "\t-o branch\tbranch for CVS HEAD\n";
    print STDERR "\t-s statefile\tcached CVS2git import state\n";
    print STDERR "\t-x\t\tignore and regenerate cached CVS2git import state\n";
}

sub HELP_MESSAGE
{
    usage();
}

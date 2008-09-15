#!/usr/bin/env perl
use strict;
use warnings;

use Safe;
use Email::Simple;
use LWP::Simple;
use Getopt::Long;
use POE qw( 
  Component::Client::NNTP::Tail
  Component::Client::SMTP
);

#--------------------------------------------------------------------------#
# FIXED PARAMETERS
#--------------------------------------------------------------------------#

my $nntpserver  = "nntp.perl.org";
my $group       = "perl.cpan.testers";

#--------------------------------------------------------------------------#
# COMMAND LINE PARAMETERS
#--------------------------------------------------------------------------#

my ($author,@grades,$help);
my $mirror      = "http://cpan.pair.com/";
my $smtp        = "mx.perl.org" ; # maybe change to your ISP's server

GetOptions( 
  'author=s'  => \$author,
  'grade=s'   => \@grades,
  'smtp=s'    => \$smtp,
  'mirror=s'  => \$mirror,
  'help'      => \$help
);

die << "END_USAGE" if $help || ! ( $author && @grades );
Usage: $0 OPTIONS

Options:
  --author=AUTHORID     CPAN author ID (required)

  --grade=GRADE         PASS, FAIL, UNKNOWN or NA (required, multiple ok)
  
  --smtp=SERVER         SMTP relay server; defaults to mx.perl.org
  
  --mirror=MIRROR       CPAN mirror; defaults to http://cpan.pair.com/

  --help                hows this usage info
END_USAGE

my $checksum_path;
$author = uc $author; # DWIM
if ($author =~ /^(([a-z])[a-z])[a-z]+$/i) {
  $checksum_path="authors/id/$2/$1/$author/CHECKSUMS";
}
else {
  die "$0: '$author' doesn't seem to be a proper CPAN author ID\n";
}

for my $g ( @grades ) {
  $g = uc $g; # DWIM
  die "$0: '$g' is not a valid grade (PASS, FAIL, UNKNOWN or NA)\n"
    unless $g =~ /^(?:PASS|FAIL|UNKNOWN|NA)$/;
}

# make sure mirror ends with slash
$mirror =~ s{/$}{};
$mirror .= "/";

#--------------------------------------------------------------------------#
# PROGRAM CODE
#--------------------------------------------------------------------------#

POE::Component::Client::NNTP::Tail->spawn(
  NNTPServer  => $nntpserver,
  Group       => $group,
);

POE::Session->create(
  package_states => [
    main => [qw(_start refresh_dist_list new_header got_article)]
  ],
);

POE::Kernel->run;
exit 0;

#--------------------------------------------------------------------------#
# EVENT HANDLERS
#--------------------------------------------------------------------------#

sub _start {
  $_[KERNEL]->call( $_[SESSION], 'refresh_dist_list' );
  $_[KERNEL]->post( $group => 'register' );
  return;
}

# get $author CHECKSUMS file and put dist list in heap  
sub refresh_dist_list {
  my $url = "${mirror}${checksum_path}";
  my $file = get($url);
  die "$0: error getting $url\n" unless defined $file;
  $file =~ s/\015?\012/\n/;
  my $safe = Safe->new;
  my $checksums = $safe->reval($file);
  if ( ref $checksums eq 'HASH' ) {
    # clear dist list
    $_[HEAP]->{dists} = {};
    for my $f ( keys %$checksums ) {
      # use the .meta key so we don't worry about tarball suffixes
      next unless $f =~ /.meta$/;
      $f =~ s/.meta$//;
      $_[HEAP]->{dists}{$f} = 1;
    }
  }
  else {
    die "$0: Couldn't get distributions by $author from $mirror\n";
  }
  # refresh in 12 hours
  $_[KERNEL]->delay( 'refresh_dist_list' => 3600 * 12 );
  return;
}

sub new_header {
  my ($article_id, $lines) = @_[ARG0, ARG1];
  my $article = Email::Simple->new( join "\015\012", @$lines );
  my $subject = $article->header('Subject');
  my ($grade, $dist) = split " ", $subject;
  if ( $_[HEAP]->{dists}{$dist} && grep { $grade eq $_ } @grades ) {
    $_[KERNEL]->post( $group => 'get_article' => $article_id );
  }
  return;
}

sub got_article {
  my ($article_id, $lines) = @_[ARG0, ARG1];
  my $article = Email::Simple->new( join "\015\012", @$lines );
  # eventually send email w PoCo::Client::SMTP  
  print $article->header('Subject'), "\n";
}


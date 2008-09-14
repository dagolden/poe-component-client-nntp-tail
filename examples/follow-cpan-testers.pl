#!/usr/bin/env perl
use strict;
use warnings;

#sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Component::Client::NNTP::Tail);
use Email::Simple;

my $server  = "nntp.perl.org";
my $group   = "perl.cpan.testers";

POE::Component::Client::NNTP::Tail->spawn(
  server        => $server,
  group         => $group,
  poll          => 60,
);

POE::Session->create(
  package_states => [
    main => [qw(_start new_article)]
  ],
);

POE::Kernel->run;
exit 0;

sub _start {
  $_[KERNEL]->post( $group => 'register' );
  return;
}

sub new_article {
  my ($response, $lines) = @_[ARG0, ARG1];
  my $article = Email::Simple->new( join "\n", @$lines );
  print $article->header('Subject'), "\n";
  return;
}

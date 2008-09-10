# Copyright (c) 2008 by David Golden. All rights reserved.
# Licensed under Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://www.apache.org/licenses/LICENSE-2.0

package POE::Component::Client::NNTP::Tail;
use strict;
use warnings;

our $VERSION = '0.01';
$VERSION = eval $VERSION; ## no critic

use Carp;
use POE qw(Component::Client::NNTP);

sub spawn {
  my $class = shift;
  my %opts = @_;
  # XXX validate options
  POE::Session->create(
    args => [ \%opts ], 
    package_states => [
      $class => { 
        nntp_connected    => 'nntp_connected',
        nntp_registered   => 'nntp_registered', 
        nntp_socketerr    => 'nntp_socketerr',
        nntp_disconnected => 'nntp_disconnected',
        nntp_200	        => 'nntp_server_ready',
        nntp_201          => 'nntp_server_ready',
        nntp_211	        => 'nntp_group_selected',
        nntp_220	        => 'nntp_got_article',
      },
      $class => [ qw(
        _start
        _stop 
        _child 
        dispatch 
        poll 
        reconnect 
        register 
        unregister
      ) ],
    ],
  );
}
  
sub _start {
  my ( $kernel, $heap, $args ) = @_[KERNEL, HEAP, ARG0];
  $kernel->alias_set($args->{group});
  $heap->{poll} = $args->{poll};
  $heap->{group} = $args->{group};
  $heap->{count} = 0;
  $heap->{nntp} = POE::Component::Client::NNTP->spawn(
    "NNTP-Client", { NNTPServer => $args->{server} }
  );
  $kernel->post( 'NNTP-Client' => 'register' => 'all' );
  $kernel->post( 'NNTP-Client' => 'connect' );
  return;
}

sub _child {}

sub _stop {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  $kernel->post( 'NNTP-Client' => 'unregister' => 'all' );
  $kernel->post( 'NNTP-Client' => 'shutdown' );
  $kernel->alias_remove($heap->{group});
  return;
}

#--------------------------------------------------------------------------#
# events from our clients
#--------------------------------------------------------------------------#

sub register {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  $kernel->refcount_increment( $sender->ID, __PACKAGE__ );
  $heap->{listeners}{$sender} = 1;
  return;
}

sub unregister {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  $kernel->refcount_decrement( $sender->ID, __PACKAGE__ );
  delete $heap->{listeners}{$sender};
  return;
}

#--------------------------------------------------------------------------#
# our internal events
#--------------------------------------------------------------------------#

sub poll {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  if ( $heap->{connected} ) {
    $kernel->post( 'NNTP-Client' => group => $heap->{group} );
  }
  else {
    $kernel->yield( 'reconnect' );
  }
  return;
}

sub reconnect {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  $kernel->post( 'NNTP-Client' => 'connect' );
  return;
}

sub dispatch {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  my ($event, @args) = @_[ARG0 .. $#_];
  for my $session ( keys %{ $heap->{listeners} } ) {
    $kernel->post( $session => $event => @args );
  }
  return;
}

#--------------------------------------------------------------------------#
# events from NNTP client
#--------------------------------------------------------------------------#

sub nntp_registered {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  return;
}

sub nntp_connected {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  return;
}

# if connection can't be made, wait for next poll period to try again
sub nntp_socketerr {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  my ($error) = $_[ARG0];
  warn "Socket error: $error\n";
  $heap->{connected} = 0;
  $kernel->delay( 'reconnect' => $heap->{poll} );
  return;
}

# if we time-out, just note it and wait for next poll to reconnect
sub nntp_disconnected {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  $heap->{connected} = 0;
  return;
}

sub nntp_server_ready {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  $heap->{connected} = 1;
  $kernel->yield( 'poll' );
  undef;
}

sub nntp_group_selected {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  my ($estimate,$first,$last,$group) = split( /\s+/, $_[ARG0] );

  # first time, we just need to record the last article
  if ( ! exists $heap->{last_article} ) {
     $heap->{last_article} = $last;
  }
  # otherwise, we need to fetch any new articles
  else {
    for my $article_id ( $heap->{last_article} + 1 .. $last ) {
      $kernel->post( $sender => article => $article_id );
    }
  }
  $kernel->delay( 'poll' => $heap->{poll} );
  return;
}

sub nntp_got_article {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  $kernel->yield( dispatch => 'new_article' => @_[ARG0, ARG1] );
  return;
}

 
1;

__END__

=begin wikidoc

= NAME

POE::Component::Client::NNTP::Tail - Sends events for new articles posted to an NNTP newsgroup

= VERSION

This documentation describes version %%VERSION%%.

= SYNOPSIS

  use POE qw( Component::Client::NNTP::Tail );
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

  # print subject line to terminal
  sub new_article {
    my ($response, $lines) = @_[ARG0, ARG1];
    my $article = Email::Simple->new( join "\n", @$lines );
    print $article->header('Subject'), "\n";
    return;
  }

= DESCRIPTION


= USAGE


= BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
[http://rt.cpan.org/Dist/Display.html?Queue=POE-Component-Client-NNTP-Tail]

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

= SEE ALSO

* [POE]
* [POE::Component::Client::NNTP]

= AUTHOR

David A. Golden (DAGOLDEN)

Substantial portions based on code in POE::Component::SmokeBox::Uploads::NNTP
by Chris Williams.

= COPYRIGHT AND LICENSE

Copyright (c) 2008 by David A. Golden. All rights reserved.

Licensed under Apache License, Version 2.0 (the "License").
You may not use this file except in compliance with the License.
A copy of the License was distributed with this file or you may obtain a 
copy of the License from http://www.apache.org/licenses/LICENSE-2.0

Files produced as output though the use of this software, shall not be
considered Derivative Works, but shall be considered the original work of the
Licensor.

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=end wikidoc

=cut


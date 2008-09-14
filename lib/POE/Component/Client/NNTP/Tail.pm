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
use Params::Validate;
use POE qw(Component::Client::NNTP);

my %spawn_args = (
  # required
  Group         => 1,
  NNTPServer    => 1,
  # optional with defaults
  Interval      => { default => 60 },
  # purely optional
  Port          => 0,
  LocalAddr     => 0,
  Alias         => 0,
  Debug         => 0,
);

sub spawn {
  my $class = shift;
  my %opts = validate( @_, \%spawn_args );

  POE::Session->create(
    heap => \%opts, 
    package_states => [
      # nntp component events
      $class => { 
        nntp_connected    => '_nntp_connected',
        nntp_registered   => '_nntp_registered', 
        nntp_socketerr    => '_nntp_socketerr',
        nntp_disconnected => '_nntp_disconnected',
        nntp_200	        => '_nntp_server_ready',
        nntp_201          => '_nntp_server_ready',
        nntp_211	        => '_nntp_group_selected',
        nntp_220	        => '_nntp_got_article',
        nntp_221	        => '_nntp_got_head',
      },
      # session events
      $class => [ qw( _start _stop _child  ) ],
      # internal events
      $class => [ qw( _poll _reconnect ) ],
      # API events
      $class => [ qw( register unregister get_article ) ],
    ],
  );
}
  
sub _debug {
  my $where = (caller(1))[3];
  $where =~ s{.*::}{P::C::C::N::T::};
  my @args = @_[ARG0 .. $#_];
  for ( @args ) { 
    $_ = 'undef' if not defined $_;
  }
  my $args = @args ? join( " " => "", (map { "'$_'" } @args), "" ) : ""; 
  warn "$where->($args)\n";
  return;
}

#--------------------------------------------------------------------------#
# session events
#--------------------------------------------------------------------------#

sub _start {
  my ( $kernel, $session, $heap ) = @_[KERNEL, SESSION, HEAP];
  &_debug if $heap->{Debug};

  # alias defaults to group name if not otherwise set
  $heap->{Alias} = $heap->{Group} unless exists $heap->{Alias};
  $kernel->alias_set($heap->{Alias});

  # setup NNTP including optional args if defined;
  my %nntp_args;
  for my $k ( qw/NNTPServer Port LocalAddr/ ) {
    $nntp_args{$k} = $heap->{$k} if exists $heap->{$k};
  }
  my $alias = "NNTP-Client-" . $session->ID;
  $heap->{nntp} = POE::Component::Client::NNTP->spawn($alias,\%nntp_args);
  $heap->{nntp_id} = $heap->{nntp}->session_id;

  # start NNTP connection
  $kernel->yield( '_reconnect' );
  return;
}

# ignore these
sub _child {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  &_debug if $heap->{Debug};
}

sub _stop {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  &_debug if $heap->{Debug};
  $kernel->post( $heap->{nntp_id} => 'unregister' => 'all' );
  $kernel->post( $heap->{nntp_id} => 'shutdown' );
  $kernel->alias_remove($_) for $kernel->alias_list;
  return;
}

#--------------------------------------------------------------------------#
# events from our clients
#--------------------------------------------------------------------------#

#--------------------------------------------------------------------------#
# register -- [EVENT]
#
# EVENT - event to dispatch to the registered session on receipt of new
#         headers; defaults to "new_header"
#--------------------------------------------------------------------------#

sub register {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  my ($event) = $_[ARG0] || 'new_header';
  $kernel->refcount_increment( $sender->ID, __PACKAGE__ );
  $heap->{listeners}{$sender} = $event;
  return;
}

#--------------------------------------------------------------------------#
# unregister -- 
#
# removes sender registration
#--------------------------------------------------------------------------#

sub unregister {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  $kernel->refcount_decrement( $sender->ID, __PACKAGE__ );
  delete $heap->{listeners}{$sender};
  return;
}

#--------------------------------------------------------------------------#
# get_article -- ARTICLE_ID, EVENT
#
# request ARTICLE_ID be retrieved and returned via EVENT or 'got_article
# if not specified
#--------------------------------------------------------------------------#

sub get_article {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  my ($article_id, $return_event) = @_[ARG0, ARG1];
  $return_event ||= 'got_article';
  # store requesting session and desired return event
  push @{$heap->{requests}{$article_id}}, [$sender, $return_event];
  $kernel->post( $heap->{nntp_id} => article => $article_id );
  return;
}

#--------------------------------------------------------------------------#
# our internal events
#--------------------------------------------------------------------------#

# if connected, check for new messages, otherwise reconnect
sub _poll {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  &_debug if $heap->{Debug};
  if ( $heap->{connected} ) {
    $kernel->post( $heap->{nntp_id} => group => $heap->{Group} );
  }
  else {
    $kernel->yield( '_reconnect' );
  }
  return;
}

# connect to NNTP server
sub _reconnect {
  my ( $kernel, $heap ) = @_[KERNEL, HEAP];
  &_debug if $heap->{Debug};
  $kernel->post( $heap->{nntp_id} => 'connect' );
  return;
}

#--------------------------------------------------------------------------#
# events from NNTP client
#--------------------------------------------------------------------------#

# ignore event
sub _nntp_registered {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  return;
}

# ignore event
sub _nntp_connected {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  return;
}

# if connection can't be made, wait for next poll period to try again
sub _nntp_socketerr {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  my ($error) = $_[ARG0];
  warn "Socket error: $error\n";
  $heap->{connected} = 0;
  $kernel->delay( '_reconnect' => $heap->{Interval} );
  return;
}

# if we time-out, just note it and wait for next poll to reconnect
sub _nntp_disconnected {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  $heap->{connected} = 0;
  return;
}

# once connected, start polling loop
sub _nntp_server_ready {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  $heap->{connected} = 1;
  $kernel->yield( '_poll' );
  undef;
}

# if there are new articles, request their headers
# also schedules the next check
sub _nntp_group_selected {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  my ($estimate,$first,$last,$group) = split( /\s+/, $_[ARG0] );

  # first time, we won't know last_article, so skip to the end
  if ( exists $heap->{last_article} ) {
    # fetch new headers or articles only if people are listening
    for my $article_id ( $heap->{last_article} + 1 .. $last ) {
      if ( scalar keys %{ $heap->{listeners} } ) {
        $kernel->post( $sender => head => $article_id );
      }
    }
  }
  $heap->{last_article} = $last;
  $kernel->delay( '_poll' => $heap->{Interval} );
  return;
}

# notify listeners of new header
sub _nntp_got_head {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  my ($response, $lines) = @_[ARG0, ARG1];
  my ($article_id) = split " ", $response;
  for my $who ( keys %{ $heap->{listeners} } ) {
    $kernel->post( $who => $heap->{listeners}{$who} => $article_id, $lines );
  }
  return;
}

# return article to request queue
sub _nntp_got_article {
  my ($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
  &_debug if $heap->{Debug};
  my ($response, $lines) = @_[ARG0, ARG1];
  my ($article_id) = split " ", $response;
  # dispatch for all entries in the request queue for this article
  for my $request ( @{$heap->{requests}{$article_id}} ) {
    my ($who, $event) = @$request;
    $kernel->post( $who, $event, $article_id, $lines );
  }
  # clear the request queue
  delete $heap->{requests}{$article_id};
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

  XXX replace with examples/synopsis

= DESCRIPTION

This component periodically polls an NNTP newsgroup and posts POE events to
component listeners as new articles are available.  These events contains the
article ID and header text for the given articles.  This component also
facilitates retrieving the full text of a particular article of interest.

Internally, it uses [POE::Component::Client::NNTP] to manage the NNTP session.

= USAGE

Spawn a new component session for each newsgroup to follow and send the
{register} event to specify an event to sent back when new articles arrive.

Handle the new article event. Optionally, send the {get_article} event to 
request the full text of the article.

= METHODS

== spawn

  POE::Component::Client::NNTP::Tail->spawn(
    NNTPServer  => 'nntp.perl.org',
    Group       => 'perl.cpan.testers',
  );

The {spawn} class method launches a new POE::Session to follow a given
newsgroup.  The {NNTPServer} and {Group} arguments are required, all other
arguments are optional:

* NNTPServer (required) -- name or IP address of the NNTP server
* Group (required) -- newsgroup to follow
* Interval -- minimum number of seconds between checks for new messages
(defaults to 60)
* Alias -- POE::Session alias name (defaults to the newsgroup name)
* Port -- server port for NNTP connections
* LocalAddr -- local address for outbound IP connection
* Debug -- if true, a trace of events and arguments will be printed to STDERR

You must spawn multiple times to follow multiple newsgroups.

= INPUT EVENTS

The component will respond to the following events.

== register

  $_[KERNEL]->post( 'perl.cpan.testers' => register => $event_name );

This event notifies the component to post a {new_header} event to the sender
when new articles arrive.  The event will be sent using the {$event_name}
provided, or will default to 'new_header'.  Multiple sessions may register
with a single POE::Component::Client::NNTP::Tail session.

== unregister

  $_[KERNEL]->post( 'perl.cpan.testers' => unregister );

This event will stop the component from posting new_header events to the
sender.

== get_article

  $_[KERNEL]->post( 
    'perl.cpan.testers' => get_article => $article_id => $event_name
  );

This event requests that the full text of {$article_id} be returned in a
{got_article} event.  The event will be sent using the {$event_name}
provided, or will default to 'got_article'.

= OUTPUT EVENTS

The component sends the following events types, though the actual event
name may be different depending on what is specified in the {register} and
{get_article} events.

== new_header

  ($article_id, $lines) = @_[ARG0, ARG1];

The {new_header} event is sent when new articles are found in the newsgroup.
The {$lines} argument is a reference to an array of lines that contain the
article header.  Lines have had newlines removed.

== got_article

  ($article_id, $lines) = @_[ARG0, ARG1];

The {got_article} event is sent when the full text of an article is retrieved.
The {$lines} argument is a reference to an array of lines that contain the full
article, including header and body text.  Lines have had newlines removed.

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

Portions based on or inspired by code in
POE::Component::SmokeBox::Uploads::NNTP by Chris Williams.

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


# Copyright (c) 2008 by David Golden. All rights reserved.
# Licensed under Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://www.apache.org/licenses/LICENSE-2.0

use strict;
use warnings;
use POE qw/Component::Server::NNTP/;

use Test::More tests => 1;

require_ok( 'POE::Component::Client::NNTP::Tail' );


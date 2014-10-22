package Mojolicious::Plugin::SecureCORS;

use warnings;
use strict;
use utf8;
use feature ':5.10';
use Carp;

use version; our $VERSION = qv('1.0.1');    # REMINDER: update Changes

# REMINDER: update dependencies in Build.PL
use Mojo::Base 'Mojolicious::Plugin';

use constant DEFAULT_MAX_AGE => 1800;


sub register {
    my ($self, $app, $conf) = @_;
    if (!exists $conf->{max_age}) {
        $conf->{max_age} = DEFAULT_MAX_AGE;
    }

    my $root = $app->routes;

    $root->add_shortcut(under_strict_cors => sub {
        my ($r, @args) = @_;
        return $r->bridge(@args)->to(cb => \&_strict);
    });

    $root->add_shortcut(cors => sub {
        my ($r, @args) = @_;
        return $r->route(@args)
            ->via('OPTIONS')
            ->over(
                headers => {
                    'Origin' => qr/\S/ms,
                    'Access-Control-Request-Method' => qr/\S/ms,
                },
            )
            ->to(cb => sub { _preflight($conf, @_) });
    });

    $app->hook(after_render => \&_request);

    return;
}

sub _strict {
    my ($c) = @_;

    if (!defined $c->req->headers->origin) {
        return 1;       # Not a CORS request, pass
    }

    my $r = $c->match->endpoint;
    while ($r) {
        if ($r->to->{'cors.origin'}) {
            return 1;   # Endpoint configured for CORS, pass
        }
        $r = $r->parent;
    }
    # Endpoint not configured for CORS, block
    $c->render(status => 403, text => 'CORS Forbidden');
    return;
}

sub _preflight {
    my ($conf, $c) = @_;

    my $method = $c->req->headers->header('Access-Control-Request-Method');
    my $match;
    # use options defined on this route, if available
    if ($c->match->endpoint->to->{'cors.origin'}) {
        $match = $c->match;
        my $opt_methods = $match->endpoint->to->{'cors.methods'};
        if ($opt_methods) {
            my %good_methods = map {lc $_ => 1} split /,\s*/ms, $opt_methods;
            if (!$good_methods{lc $method}) {
                return $c->render(status => 204, data => q{});      # Endpoint not found, ignore
            }
        }
    }
    # otherwise try to find route for actual request and use it options
    else {
        $match = Mojolicious::Routes::Match->new(root => $c->app->routes);
        $match->match($c, {
            method => $method,
            path => $c->req->url->path,
        });
        if (!$match->endpoint) {
            return $c->render(status => 204, data => q{});      # Endpoint not found, ignore
        }
    }

    my %opt = _get_opt($match->endpoint);

    if (!$opt{origin}) {
        return $c->render(status => 204, data => q{});      # Endpoint not configured for CORS, ignore
    }

    my $h = $c->res->headers;
    $h->append(Vary => 'Origin');

    my $origin = $c->req->headers->origin;
    if (ref $opt{origin} eq 'Regexp') {
        if ($origin !~ /$opt{origin}/ms) {
            return $c->render(status => 204, data => q{});  # Bad Origin:
        }
    } else {
        if (!grep {$_ eq q{*} || $_ eq $origin} split q{ }, $opt{origin}) {
            return $c->render(status => 204, data => q{});  # Bad Origin:
        }
    }

    my $headers = $c->req->headers->header('Access-Control-Request-Headers');
    my @want_headers = map {lc} split /,\s*/ms, $headers // q{};
    if (ref $opt{headers} eq 'Regexp') {
        if (grep {!/$opt{headers}/ms} @want_headers) {
            return $c->render(status => 204, data => q{});  # Bad Access-Control-Request-Headers:
        }
    } else {
        my %good_headers = map {lc $_ => 1} split /,\s*/ms, $opt{headers};
        if (grep {!exists $good_headers{$_}} @want_headers) {
            return $c->render(status => 204, data => q{});  # Bad Access-Control-Request-Headers:
        }
    }

    $h->header('Access-Control-Allow-Origin' => $origin);
    $h->header('Access-Control-Allow-Methods' => $method);
    if (defined $headers) {
        $h->header('Access-Control-Allow-Headers' => $headers);
    }
    if ($opt{credentials}) {
        $h->header('Access-Control-Allow-Credentials' => 'true');
    }
    if (defined $conf->{max_age}) {
        $h->header('Access-Control-Max-Age' => $conf->{max_age});
    }
    return $c->render(status => 204, data => q{});
}

sub _request {
    my ($c, $output, $format) = @_;

    my %opt = _get_opt($c->match->endpoint);

    if (!$opt{origin}) {
        return;     # Endpoint not configured for CORS, ignore
    }

    my $h = $c->res->headers;
    $h->append(Vary => 'Origin');

    my $origin = $c->req->headers->origin;
    if (!defined $origin) {
        return;     # Not a CORS
    }

    if (ref $opt{origin} eq 'Regexp') {
        if ($origin !~ /$opt{origin}/ms) {
            return;     # Bad Origin:
        }
    } else {
        if (!grep {$_ eq q{*} || $_ eq $origin} split q{ }, $opt{origin}) {
            return;     # Bad Origin:
        }
    }

    $h->header('Access-Control-Allow-Origin' => $origin);
    if ($opt{credentials}) {
        $h->header('Access-Control-Allow-Credentials' => 'true');
    }
    if ($opt{expose}) {
        $h->header('Access-Control-Expose-Headers' => $opt{expose});
    }
    return;
}

sub _get_opt {
    my ($r) = @_;
    my %opt;
    while ($r) {
        for my $name (qw( origin credentials expose headers )) {
            if (!exists $opt{$name} && exists $r->to->{"cors.$name"}) {
                $opt{$name} = $r->to->{"cors.$name"};
            }
        }
        $r = $r->parent;
    }
    return %opt;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::SecureCORS - Complete control over CORS


=head1 SYNOPSIS

  # in Mojolicious app
  sub startup {
    my $app = shift;
    …

    # load and configure
    $app->plugin('SecureCORS');
    $app->plugin('SecureCORS', { max_age => undef });

    # set app-wide CORS defaults
    $app->routes->to('cors.credentials'=>1);

    # set default CORS options for nested routes
    $r = $r->under(…, {'cors.origin' => '*'}, …);

    # set CORS options for this route (at least "origin" option must be
    # defined to allow CORS, either here or in parent routes)
    $r->get(…, {'cors.origin' => '*'}, …);
    $r->route(…)->to('cors.origin' => '*');

    # allow non-simple (with preflight) CORS on this route
    $r->cors(…);

    # create bridge to protect all nested routes
    $r = $app->routes->under_strict_cors('/resource');


=head1 DESCRIPTION

L<Mojolicious::Plugin::SecureCORS> is a plugin that allow you to configure
Cross Origin Resource Sharing for routes in L<Mojolicious> app.

Implements this spec: L<http://www.w3.org/TR/2014/REC-cors-20140116/>.

=head2 SECURITY

Don't use the lazy C<< 'cors.origin'=>'*' >> for resources which should be
available only for intranet or which behave differently when accessed from
intranet - otherwise malicious website opened in browser running on
workstation in intranet will get access to these resources.

Don't use the lazy C<< 'cors.origin'=>'*' >> for resources which should be
available only from some known websites - otherwise other malicious website
will be able to attack your site by injecting JavaScript into the victim's
browser.

Consider using C<under_strict_cors()> - it won't "save" you but may helps.


=head1 INTERFACE

=over

=item CORS options

To allow CORS on some route you should define relevant CORS options for
that route. These options will be processed automatically using
L<Mojolicious/"after_render"> hook and result in adding corresponding HTTP
headers to the response.

Options should be added into default parameters for the route or it parent
routes. Defining CORS options on parent route allow you to set some
predefined defaults for their nested routes.

=over

=item C<< 'cors.origin' => '*' >>

=item C<< 'cors.origin' => 'null' >>

=item C<< 'cors.origin' => 'http://example.com' >>

=item C<< 'cors.origin' => 'https://example.com http://example.com:8080 null' >>

=item C<< 'cors.origin' => qr/\.local\z/ms >>

=item C<< 'cors.origin' => undef >> (default)

This option is required to enable CORS support for the route.

Only matched origins will be allowed to process returned response
(C<'*'> will match any origin).

When set to false value no origins will match, so it effectively disable
CORS support (may be useful if you've set this option value on parent
route).

=item C<< 'cors.credentials' => 1 >>

=item C<< 'cors.credentials' => undef >> (default)

While handling preflight request true/false value will tell browser to
send or not send credentials (cookies, http auth, ssl certificate) with
actual request.

While handling simple/actual request if set to false and browser has sent
credentials will disallow to process returned response.

=item C<< 'cors.expose' => 'X-Some' >>

=item C<< 'cors.expose' => 'X-Some, X-Other, Server' >>

=item C<< 'cors.expose' => undef >> (default)

Allow access to these headers while processing returned response.

These headers doesn't need to be included in this option:

  Cache-Control
  Content-Language
  Content-Type
  Expires
  Last-Modified
  Pragma

=item C<< 'cors.headers' => 'X-Requested-With' >>

=item C<< 'cors.headers' => 'X-Requested-With, Content-Type, X-Some' >>

=item C<< 'cors.headers' => qr/\AX-|\AContent-Type\z/msi >>

=item C<< 'cors.headers' => undef >> (default)

Define headers which browser is allowed to send. Work only for non-simple
CORS because it require preflight.

=item C<< 'cors.methods' => 'POST' >>

=item C<< 'cors.methods' => 'GET, POST, PUT, DELETE' >>

This option can be used only for C<cors()> route. It's needed in complex
cases when it's impossible to automatically detect CORS option while
handling preflight - see below for example.

=back

=item $r->cors(…)

Accept same params as L<Mojolicious::Routes::Route/"route">.

Add handler for preflight (OPTIONS) CORS request - it's required to allow
non-simple CORS requests on given path.

To be able to respond on preflight request this handler should know CORS
options for requested method/path. In most cases it will be able to detect
them automatically by searching for route defined for same path and HTTP
method given in CORS request. Example:

    $r->cors('/rpc');
    $r->get('/rpc', { 'cors.origin' => 'http://example.com' });
    $r->put('/rpc', { 'cors.origin' => qr/\.local\z/ms });

But in some cases target route can't be detected, for example if you've
defined several routes for same path using different conditions which
can't be checked while processing preflight request because browser didn't
sent enough information yet (like C<Content-Type:> value which will be
used in actual request). In this case you should manually define all
relevant CORS options on preflight route - in addition to CORS options
defined on target routes. Because you can't know which one of defined
routes will be used to handle actual request, in case they use different
CORS options you should use combined in less restrictive way options for
preflight route. Example:

    $r->cors('/rpc')->to(
        'cors.methods'      => 'GET, POST',
        'cors.origin'       => 'http://localhost http://example.com',
        'cors.credentials'  => 1,
    );
    $r->any([qw(GET POST)] => '/rpc',
        headers => { 'Content-Type' => 'application/json-rpc' },
    )->to('jsonrpc#handler',
        'cors.origin'       => 'http://localhost',
    );
    $r->post('/rpc',
        headers => { 'Content-Type' => 'application/soap+xml' },
    )->to('soaprpc#handler',
        'cors.origin'       => 'http://example.com',
        'cors.credentials'  => 1,
    );

This route use "headers" condition, so you can add your own handler for
OPTIONS method on same path after this one, to handle non-CORS OPTIONS
requests on same path.

=item $bridge = $r->under_strict_cors(…)

Accept same params as L<Mojolicious::Routes::Route/"bridge">.

Under returned bridge CORS requests to any route which isn't configured
for CORS (i.e. won't have C<'cors.origin'> in route's default parameters)
will be rendered as "403 Forbidden".

This feature should make it harder to attack your site by injecting
JavaScript into the victim's browser on vulnerable website. More details:
L<https://code.google.com/p/html5security/wiki/CrossOriginRequestSecurity#Processing_rogue_COR:>.

=back


=head1 OPTIONS

L<Mojolicious::Plugin::SecureCORS> supports the following options.

=head2 max_age

  $app->plugin('SecureCORS', { max_age => undef });

Value for C<Access-Control-Max-Age:> sent by preflight OPTIONS handler.
If set to C<undef> this header will not be sent.

Default is 1800 (30 minutes).


=head1 METHODS

L<Mojolicious::Plugin::SecureCORS> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new);
  $plugin->register(Mojolicious->new, { max_age => undef });

Register hooks in L<Mojolicious> application.


=head1 SEE ALSO

L<Mojolicious>.


=head1 BUGS AND LIMITATIONS

No bugs have been reported.


=head1 SUPPORT

Please report any bugs or feature requests through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Mojolicious-Plugin-SecureCORS>.
I will be notified, and then you'll automatically be notified of progress
on your bug as I make changes.

You can also look for information at:

=over

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Mojolicious-Plugin-SecureCORS>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Mojolicious-Plugin-SecureCORS>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Mojolicious-Plugin-SecureCORS>

=item * Search CPAN

L<http://search.cpan.org/dist/Mojolicious-Plugin-SecureCORS/>

=back


=head1 AUTHOR

Alex Efros  C<< <powerman@cpan.org> >>


=head1 LICENSE AND COPYRIGHT

Copyright 2014 Alex Efros <powerman@cpan.org>.

This program is distributed under the MIT (X11) License:
L<http://www.opensource.org/licenses/mit-license.php>

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.


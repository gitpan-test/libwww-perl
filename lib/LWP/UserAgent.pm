package LWP::UserAgent;

use strict;
use vars qw(@ISA $VERSION);

require LWP::MemberMixin;
@ISA = qw(LWP::MemberMixin);
$VERSION = "5.816";

use HTTP::Request ();
use HTTP::Response ();
use HTTP::Date ();

use LWP ();
use LWP::Debug ();
use LWP::Protocol ();

use Carp ();

if ($ENV{PERL_LWP_USE_HTTP_10}) {
    require LWP::Protocol::http10;
    LWP::Protocol::implementor('http', 'LWP::Protocol::http10');
    eval {
        require LWP::Protocol::https10;
        LWP::Protocol::implementor('https', 'LWP::Protocol::https10');
    };
}



sub new
{
    # Check for common user mistake
    Carp::croak("Options to LWP::UserAgent should be key/value pairs, not hash reference") 
        if ref($_[1]) eq 'HASH'; 

    my($class, %cnf) = @_;
    LWP::Debug::trace('()');

    my $agent = delete $cnf{agent};
    my $from  = delete $cnf{from};
    my $timeout = delete $cnf{timeout};
    $timeout = 3*60 unless defined $timeout;
    my $use_eval = delete $cnf{use_eval};
    $use_eval = 1 unless defined $use_eval;
    my $parse_head = delete $cnf{parse_head};
    $parse_head = 1 unless defined $parse_head;
    my $show_progress = delete $cnf{show_progress};
    my $max_size = delete $cnf{max_size};
    my $max_redirect = delete $cnf{max_redirect};
    $max_redirect = 7 unless defined $max_redirect;
    my $env_proxy = delete $cnf{env_proxy};

    my $cookie_jar = delete $cnf{cookie_jar};
    my $conn_cache = delete $cnf{conn_cache};
    my $keep_alive = delete $cnf{keep_alive};
    
    Carp::croak("Can't mix conn_cache and keep_alive")
	  if $conn_cache && $keep_alive;


    my $protocols_allowed   = delete $cnf{protocols_allowed};
    my $protocols_forbidden = delete $cnf{protocols_forbidden};
    
    my $requests_redirectable = delete $cnf{requests_redirectable};
    $requests_redirectable = ['GET', 'HEAD']
      unless defined $requests_redirectable;

    # Actually ""s are just as good as 0's, but for concision we'll just say:
    Carp::croak("protocols_allowed has to be an arrayref or 0, not \"$protocols_allowed\"!")
      if $protocols_allowed and ref($protocols_allowed) ne 'ARRAY';
    Carp::croak("protocols_forbidden has to be an arrayref or 0, not \"$protocols_forbidden\"!")
      if $protocols_forbidden and ref($protocols_forbidden) ne 'ARRAY';
    Carp::croak("requests_redirectable has to be an arrayref or 0, not \"$requests_redirectable\"!")
      if $requests_redirectable and ref($requests_redirectable) ne 'ARRAY';


    if (%cnf && $^W) {
	Carp::carp("Unrecognized LWP::UserAgent options: @{[sort keys %cnf]}");
    }

    my $self = bless {
		      def_headers  => undef,
		      timeout      => $timeout,
		      use_eval     => $use_eval,
                      show_progress=> $show_progress,
		      max_size     => $max_size,
		      max_redirect => $max_redirect,
                      proxy        => {},
		      no_proxy     => [],
                      protocols_allowed     => $protocols_allowed,
                      protocols_forbidden   => $protocols_forbidden,
                      requests_redirectable => $requests_redirectable,
		     }, $class;

    $self->agent($agent || $class->_agent);
    $self->from($from) if $from;
    $self->cookie_jar($cookie_jar) if $cookie_jar;
    $self->parse_head($parse_head);
    $self->env_proxy if $env_proxy;

    $self->protocols_allowed(  $protocols_allowed  ) if $protocols_allowed;
    $self->protocols_forbidden($protocols_forbidden) if $protocols_forbidden;

    if ($keep_alive) {
	$conn_cache ||= { total_capacity => $keep_alive };
    }
    $self->conn_cache($conn_cache) if $conn_cache;

    return $self;
}


sub send_request
{
    my($self, $request, $arg, $size) = @_;
    my($method, $url) = ($request->method, $request->uri);
    my $scheme = $url->scheme;

    local($SIG{__DIE__});  # protect against user defined die handlers

    LWP::Debug::trace("$method $url");

    $self->progress("begin", $request);

    my $response = $self->run_handlers("request_send", $request);

    unless ($response) {
        my $protocol;

        {
            # Honor object-specific restrictions by forcing protocol objects
            #  into class LWP::Protocol::nogo.
            my $x;
            if($x = $self->protocols_allowed) {
                if (grep lc($_) eq $scheme, @$x) {
                    LWP::Debug::trace("$scheme URLs are among $self\'s allowed protocols (@$x)");
                }
                else {
                    LWP::Debug::trace("$scheme URLs aren't among $self\'s allowed protocols (@$x)");
                    require LWP::Protocol::nogo;
                    $protocol = LWP::Protocol::nogo->new;
                }
            }
            elsif ($x = $self->protocols_forbidden) {
                if(grep lc($_) eq $scheme, @$x) {
                    LWP::Debug::trace("$scheme URLs are among $self\'s forbidden protocols (@$x)");
                    require LWP::Protocol::nogo;
                    $protocol = LWP::Protocol::nogo->new;
                }
                else {
                    LWP::Debug::trace("$scheme URLs aren't among $self\'s forbidden protocols (@$x)");
                }
            }
            # else fall thru and create the protocol object normally
        }

        # Locate protocol to use
        my $proxy = $request->{proxy};
        if ($proxy) {
            $scheme = $proxy->scheme;
        }

        unless ($protocol) {
            $protocol = eval { LWP::Protocol::create($scheme, $self) };
            if ($@) {
                $@ =~ s/ at .* line \d+.*//s;  # remove file/line number
                my $response =  _new_response($request, &HTTP::Status::RC_NOT_IMPLEMENTED, $@);
                if ($scheme eq "https") {
                    $response->message($response->message . " (Crypt::SSLeay not installed)");
                    $response->content_type("text/plain");
                    $response->content(<<EOT);
LWP will support https URLs if the Crypt::SSLeay module is installed.
More information at <http://www.linpro.no/lwp/libwww-perl/README.SSL>.
EOT
                }
            }
        }

        if (!$response && $self->{use_eval}) {
            # we eval, and turn dies into responses below
            eval {
                $response = $protocol->request($request, $proxy,
                                               $arg, $size, $self->{timeout});
            };
            if ($@) {
                $@ =~ s/ at .* line \d+.*//s;  # remove file/line number
                    $response = _new_response($request,
                                              &HTTP::Status::RC_INTERNAL_SERVER_ERROR,
                                              $@);
            }
        }
        elsif (!$response) {
            $response = $protocol->request($request, $proxy,
                                           $arg, $size, $self->{timeout});
            # XXX: Should we die unless $response->is_success ???
        }
    }

    $response->request($request);  # record request for reference
    $response->header("Client-Date" => HTTP::Date::time2str(time));

    $self->run_handlers("response_done", $response);

    $self->progress("end", $response);
    return $response;
}


sub prepare_request
{
    my($self, $request) = @_;
    # sanity check the request passed in
    if (defined $request) {
	if (ref $request) {
	    Carp::croak("You need a request object, not a " . ref($request) . " object")
	      if ref($request) eq 'ARRAY' or ref($request) eq 'HASH' or
		 !$request->can('method') or !$request->can('uri');
	}
	else {
	    Carp::croak("You need a request object, not '$request'");
	}
    }
    else {
        Carp::croak("No request object passed in");
    }
    Carp::croak("Bad request: Method missing") unless $request->method;
    my $url = $request->url;
    Carp::croak("Bad request: URL missing") unless $url;
    Carp::croak("Bad request: URL must be absolute") unless $url->scheme;

    $self->run_handlers("request_preprepare", $request);

    my $max_size = $self->{max_size};
    if (defined $max_size) {
	my $last = $max_size - 1;
	$last = 0 if $last < 0;  # there is no way to actually request no content
	$request->init_header('Range' => "bytes=0-$last");
    }

    if (my $def_headers = $self->{def_headers}) {
	for my $h ($def_headers->header_field_names) {
	    $request->init_header($h => [$def_headers->header($h)]);
	}
    }

    $self->run_handlers("request_prepare", $request);

    return $request;
}


sub simple_request
{
    my($self, $request, $arg, $size) = @_;
    $request = $self->prepare_request($request);
    return $self->send_request($request, $arg, $size);
}


sub request
{
    my($self, $request, $arg, $size, $previous) = @_;

    LWP::Debug::trace('()');

    my $response = $self->simple_request($request, $arg, $size);

    if ($previous) {
        $response->previous($previous);

	# Check for loop in the redirects, we only count
	my $count = 0;
	my $r = $response;
	while ($r) {
	    if (++$count > $self->{max_redirect}) {
		$response->header("Client-Warning" =>
				  "Redirect loop detected (max_redirect = $self->{max_redirect})");
		return $response;
	    }
	    $r = $r->previous;
	}
    }

    if (my $req = $self->run_handlers("response_redirect", $response)) {
        return $self->request($req, $arg, $size, $response);
    }


    my $code = $response->code;
    LWP::Debug::debug('Simple response: ' .
		      (HTTP::Status::status_message($code) ||
		       "Unknown code $code"));

    if ($code == &HTTP::Status::RC_MOVED_PERMANENTLY or
	$code == &HTTP::Status::RC_FOUND or
	$code == &HTTP::Status::RC_SEE_OTHER or
	$code == &HTTP::Status::RC_TEMPORARY_REDIRECT)
    {
	my $referral = $request->clone;

	# These headers should never be forwarded
	$referral->remove_header('Host', 'Cookie');
	
	if ($referral->header('Referer') &&
	    $request->url->scheme eq 'https' &&
	    $referral->url->scheme eq 'http')
	{
	    # RFC 2616, section 15.1.3.
	    LWP::Debug::trace("https -> http redirect, suppressing Referer");
	    $referral->remove_header('Referer');
	}

	if ($code == &HTTP::Status::RC_SEE_OTHER ||
	    $code == &HTTP::Status::RC_FOUND) 
        {
	    my $method = uc($referral->method);
	    unless ($method eq "GET" || $method eq "HEAD") {
		$referral->method("GET");
		$referral->content("");
		$referral->remove_content_headers;
	    }
	}

	# And then we update the URL based on the Location:-header.
	my $referral_uri = $response->header('Location');
	{
	    # Some servers erroneously return a relative URL for redirects,
	    # so make it absolute if it not already is.
	    local $URI::ABS_ALLOW_RELATIVE_SCHEME = 1;
	    my $base = $response->base;
	    $referral_uri = "" unless defined $referral_uri;
	    $referral_uri = $HTTP::URI_CLASS->new($referral_uri, $base)
		            ->abs($base);
	}
	$referral->url($referral_uri);

	return $response unless $self->redirect_ok($referral, $response);
	return $self->request($referral, $arg, $size, $response);

    }
    elsif ($code == &HTTP::Status::RC_UNAUTHORIZED ||
	     $code == &HTTP::Status::RC_PROXY_AUTHENTICATION_REQUIRED
	    )
    {
	my $proxy = ($code == &HTTP::Status::RC_PROXY_AUTHENTICATION_REQUIRED);
	my $ch_header = $proxy ?  "Proxy-Authenticate" : "WWW-Authenticate";
	my @challenge = $response->header($ch_header);
	unless (@challenge) {
	    $response->header("Client-Warning" => 
			      "Missing Authenticate header");
	    return $response;
	}

	require HTTP::Headers::Util;
	CHALLENGE: for my $challenge (@challenge) {
	    $challenge =~ tr/,/;/;  # "," is used to separate auth-params!!
	    ($challenge) = HTTP::Headers::Util::split_header_words($challenge);
	    my $scheme = lc(shift(@$challenge));
	    shift(@$challenge); # no value
	    $challenge = { @$challenge };  # make rest into a hash
	    for (keys %$challenge) {       # make sure all keys are lower case
		$challenge->{lc $_} = delete $challenge->{$_};
	    }

	    unless ($scheme =~ /^([a-z]+(?:-[a-z]+)*)$/) {
		$response->header("Client-Warning" => 
				  "Bad authentication scheme '$scheme'");
		return $response;
	    }
	    $scheme = $1;  # untainted now
	    my $class = "LWP::Authen::\u$scheme";
	    $class =~ s/-/_/g;

	    no strict 'refs';
	    unless (%{"$class\::"}) {
		# try to load it
		eval "require $class";
		if ($@) {
		    if ($@ =~ /^Can\'t locate/) {
			$response->header("Client-Warning" =>
					  "Unsupported authentication scheme '$scheme'");
		    }
		    else {
			$response->header("Client-Warning" => $@);
		    }
		    next CHALLENGE;
		}
	    }
	    unless ($class->can("authenticate")) {
		$response->header("Client-Warning" =>
				  "Unsupported authentication scheme '$scheme'");
		next CHALLENGE;
	    }
	    return $class->authenticate($self, $proxy, $challenge, $response,
					$request, $arg, $size);
	}
	return $response;
    }
    return $response;
}


#
# Now the shortcuts...
#
sub get {
    require HTTP::Request::Common;
    my($self, @parameters) = @_;
    my @suff = $self->_process_colonic_headers(\@parameters,1);
    return $self->request( HTTP::Request::Common::GET( @parameters ), @suff );
}


sub post {
    require HTTP::Request::Common;
    my($self, @parameters) = @_;
    my @suff = $self->_process_colonic_headers(\@parameters, (ref($parameters[1]) ? 2 : 1));
    return $self->request( HTTP::Request::Common::POST( @parameters ), @suff );
}


sub head {
    require HTTP::Request::Common;
    my($self, @parameters) = @_;
    my @suff = $self->_process_colonic_headers(\@parameters,1);
    return $self->request( HTTP::Request::Common::HEAD( @parameters ), @suff );
}


sub _process_colonic_headers {
    # Process :content_cb / :content_file / :read_size_hint headers.
    my($self, $args, $start_index) = @_;

    my($arg, $size);
    for(my $i = $start_index; $i < @$args; $i += 2) {
	next unless defined $args->[$i];

	#printf "Considering %s => %s\n", $args->[$i], $args->[$i + 1];

	if($args->[$i] eq ':content_cb') {
	    # Some sanity-checking...
	    $arg = $args->[$i + 1];
	    Carp::croak("A :content_cb value can't be undef") unless defined $arg;
	    Carp::croak("A :content_cb value must be a coderef")
		unless ref $arg and UNIVERSAL::isa($arg, 'CODE');
	    
	}
	elsif ($args->[$i] eq ':content_file') {
	    $arg = $args->[$i + 1];

	    # Some sanity-checking...
	    Carp::croak("A :content_file value can't be undef")
		unless defined $arg;
	    Carp::croak("A :content_file value can't be a reference")
		if ref $arg;
	    Carp::croak("A :content_file value can't be \"\"")
		unless length $arg;

	}
	elsif ($args->[$i] eq ':read_size_hint') {
	    $size = $args->[$i + 1];
	    # Bother checking it?

	}
	else {
	    next;
	}
	splice @$args, $i, 2;
	$i -= 2;
    }

    # And return a suitable suffix-list for request(REQ,...)

    return             unless defined $arg;
    return $arg, $size if     defined $size;
    return $arg;
}

my @ANI = qw(- \ | /);

sub progress {
    my($self, $status, $m) = @_;
    return unless $self->{show_progress};
    if ($status eq "begin") {
        print STDERR "** ", $m->method, " ", $m->uri, " ==> ";
        $self->{progress_start} = time;
        $self->{progress_lastp} = "";
        $self->{progress_ani} = 0;
    }
    elsif ($status eq "end") {
        delete $self->{progress_lastp};
        delete $self->{progress_ani};
        print STDERR $m->status_line;
        my $t = time - delete $self->{progress_start};
        print STDERR " (${t}s)" if $t;
        print STDERR "\n";
    }
    elsif ($status eq "tick") {
        print STDERR "$ANI[$self->{progress_ani}++]\b";
        $self->{progress_ani} %= @ANI;
    }
    else {
        my $p = sprintf "%3.0f%%", $status * 100;
        return if $p eq $self->{progress_lastp};
        print STDERR "$p\b\b\b\b";
        $self->{progress_lastp} = $p;
    }
    STDERR->flush;
}


#
# This whole allow/forbid thing is based on man 1 at's way of doing things.
#
sub is_protocol_supported
{
    my($self, $scheme) = @_;
    if (ref $scheme) {
	# assume we got a reference to an URI object
	$scheme = $scheme->scheme;
    }
    else {
	Carp::croak("Illegal scheme '$scheme' passed to is_protocol_supported")
	    if $scheme =~ /\W/;
	$scheme = lc $scheme;
    }

    my $x;
    if(ref($self) and $x       = $self->protocols_allowed) {
      return 0 unless grep lc($_) eq $scheme, @$x;
    }
    elsif (ref($self) and $x = $self->protocols_forbidden) {
      return 0 if grep lc($_) eq $scheme, @$x;
    }

    local($SIG{__DIE__});  # protect against user defined die handlers
    $x = LWP::Protocol::implementor($scheme);
    return 1 if $x and $x ne 'LWP::Protocol::nogo';
    return 0;
}


sub protocols_allowed      { shift->_elem('protocols_allowed'    , @_) }
sub protocols_forbidden    { shift->_elem('protocols_forbidden'  , @_) }
sub requests_redirectable  { shift->_elem('requests_redirectable', @_) }


sub redirect_ok
{
    # RFC 2616, section 10.3.2 and 10.3.3 say:
    #  If the 30[12] status code is received in response to a request other
    #  than GET or HEAD, the user agent MUST NOT automatically redirect the
    #  request unless it can be confirmed by the user, since this might
    #  change the conditions under which the request was issued.

    # Note that this routine used to be just:
    #  return 0 if $_[1]->method eq "POST";  return 1;

    my($self, $new_request, $response) = @_;
    my $method = $response->request->method;
    return 0 unless grep $_ eq $method,
      @{ $self->requests_redirectable || [] };
    
    if ($new_request->url->scheme eq 'file') {
      $response->header("Client-Warning" =>
			"Can't redirect to a file:// URL!");
      return 0;
    }
    
    # Otherwise it's apparently okay...
    return 1;
}


sub credentials
{
    my $self = shift;
    my $netloc = lc(shift);
    my $realm = shift || "";
    my $old = $self->{basic_authentication}{$netloc}{$realm};
    if (@_) {
        $self->{basic_authentication}{$netloc}{$realm} = [@_];
    }
    return unless $old;
    return @$old if wantarray;
    return join(":", @$old);
}


sub get_basic_credentials
{
    my($self, $realm, $uri, $proxy) = @_;
    return if $proxy;
    return $self->credentials($uri->host_port, $realm);
}


sub timeout      { shift->_elem('timeout',      @_); }
sub max_size     { shift->_elem('max_size',     @_); }
sub max_redirect { shift->_elem('max_redirect', @_); }
sub show_progress{ shift->_elem('show_progress', @_); }

sub parse_head {
    my $self = shift;
    if (@_) {
        my $flag = shift;
        my $parser;
        my $old = $self->set_my_handler("response_header", $flag ? sub {
               my($response, $ua) = @_;
               require HTML::HeadParser;
               $parser = HTML::HeadParser->new($response->{'_headers'});
               $parser->xml_mode(1) if $response->content_is_xhtml;
               $parser->utf8_mode(1) if $] >= 5.008 && $HTML::Parser::VERSION >= 3.40;

               push(@{$response->{handlers}{response_data}}, sub {
                   return unless $parser;
                   $parser->parse($_[3]) or undef($parser);
               });

            } : undef,
            m_media_type => "html",
        );
        return !!$old;
    }
    else {
        return !!$self->get_my_handler("response_header");
    }
}

sub cookie_jar {
    my $self = shift;
    my $old = $self->{cookie_jar};
    if (@_) {
	my $jar = shift;
	if (ref($jar) eq "HASH") {
	    require HTTP::Cookies;
	    $jar = HTTP::Cookies->new(%$jar);
	}
	$self->{cookie_jar} = $jar;
        $self->set_my_handler("request_prepare",
            $jar ? sub { $jar->add_cookie_header($_[0]); } : undef,
        );
        $self->set_my_handler("response_done",
            $jar ? sub { $jar->extract_cookies($_[0]); } : undef,
        );
    }
    $old;
}

sub default_headers {
    my $self = shift;
    my $old = $self->{def_headers} ||= HTTP::Headers->new;
    if (@_) {
	$self->{def_headers} = shift;
    }
    return $old;
}

sub default_header {
    my $self = shift;
    return $self->default_headers->header(@_);
}

sub _agent       { "libwww-perl/$LWP::VERSION" }

sub agent {
    my $self = shift;
    if (@_) {
	my $agent = shift;
        if ($agent) {
            $agent .= $self->_agent if $agent =~ /\s+$/;
        }
        else {
            undef($agent)
        }
        return $self->default_header("User-Agent", $agent);
    }
    return $self->default_header("User-Agent");
}

sub from {  # legacy
    my $self = shift;
    return $self->default_header("From", @_);
}


sub conn_cache {
    my $self = shift;
    my $old = $self->{conn_cache};
    if (@_) {
	my $cache = shift;
	if (ref($cache) eq "HASH") {
	    require LWP::ConnCache;
	    $cache = LWP::ConnCache->new(%$cache);
	}
	$self->{conn_cache} = $cache;
    }
    $old;
}


sub add_handler {
    my($self, $phase, $cb, %spec) = @_;
    $spec{line} ||= join(":", (caller)[1,2]);
    my $conf = $self->{handlers}{$phase} ||= do {
        require HTTP::Config;
        HTTP::Config->new;
    };
    $conf->add(%spec, callback => $cb);
}

sub set_my_handler {
    my($self, $phase, $cb, %spec) = @_;
    $spec{owner} = (caller(1))[3] unless exists $spec{owner};
    $self->remove_handler($phase, %spec);
    $spec{line} ||= join(":", (caller)[1,2]);
    $self->add_handler($phase, $cb, %spec) if $cb;
}

sub get_my_handler {
    my $self = shift;
    my $phase = shift;
    my $init = pop if @_ % 2;
    my %spec = @_;
    my $conf = $self->{handlers}{$phase};
    unless ($conf) {
        return unless $init;
        require HTTP::Config;
        $conf = $self->{handlers}{$phase} = HTTP::Config->new;
    }
    $spec{owner} = (caller(1))[3] unless exists $spec{owner};
    my @h = $conf->find(%spec);
    if (!@h && $init) {
        if (ref($init) eq "CODE") {
            $init->(\%spec);
        }
        elsif (ref($init) eq "HASH") {
            while (my($k, $v) = each %$init) {
                $spec{$k} = $v;
            }
        }
        $spec{callback} ||= sub {};
        $spec{line} ||= join(":", (caller)[1,2]);
        $conf->add(\%spec);
        return \%spec;
    }
    return wantarray ? @h : $h[0];
}

sub remove_handler {
    my($self, $phase, %spec) = @_;
    if ($phase) {
        my $conf = $self->{handlers}{$phase} || return;
        my @h = $conf->remove(%spec);
        delete $self->{handlers}{$phase} if $conf->empty;
        return @h;
    }

    return unless $self->{handlers};
    return map $self->remove_handler($_), sort keys %{$self->{handlers}};
}

sub handlers {
    my($self, $phase, $o) = @_;
    my @h;
    if ($o->{handlers} && $o->{handlers}{$phase}) {
        push(@h, map +{ callback => $_ }, @{$o->{handlers}{$phase}});
    }
    if (my $conf = $self->{handlers}{$phase}) {
        push(@h, $conf->matching($o));
    }
    return @h;
}

sub run_handlers {
    my($self, $phase, $o) = @_;
    if (defined(wantarray)) {
        for my $h ($self->handlers($phase, $o)) {
            my $ret = $h->{callback}->($o, $self, $h);
            return $ret if $ret;
        }
        return undef;
    }

    for my $h ($self->handlers($phase, $o)) {
        $h->{callback}->($o, $self, $h);
    }
}


# depreciated
sub use_eval   { shift->_elem('use_eval',  @_); }
sub use_alarm
{
    Carp::carp("LWP::UserAgent->use_alarm(BOOL) is a no-op")
	if @_ > 1 && $^W;
    "";
}


sub clone
{
    my $self = shift;
    my $copy = bless { %$self }, ref $self;  # copy most fields

    delete $copy->{handlers};
    delete $copy->{conn_cache};

    # copy any plain arrays and hashes; known not to need recursive copy
    for my $k (qw(proxy no_proxy requests_redirectable)) {
        next unless $copy->{$k};
        if (ref($copy->{$k}) eq "ARRAY") {
            $copy->{$k} = [ @{$copy->{$k}} ];
        }
        elsif (ref($copy->{$k}) eq "HASH") {
            $copy->{$k} = { %{$copy->{$k}} };
        }
    }

    if ($self->{def_headers}) {
        $copy->{def_headers} = $self->{def_headers}->clone;
    }

    # re-enable standard handlers
    $copy->parse_head($self->parse_head);

    # no easy way to clone the cookie jar; so let's just remove it for now
    $copy->cookie_jar(undef);

    $copy;
}


sub mirror
{
    my($self, $url, $file) = @_;

    LWP::Debug::trace('()');
    my $request = HTTP::Request->new('GET', $url);

    if (-e $file) {
	my($mtime) = (stat($file))[9];
	if($mtime) {
	    $request->header('If-Modified-Since' =>
			     HTTP::Date::time2str($mtime));
	}
    }
    my $tmpfile = "$file-$$";

    my $response = $self->request($request, $tmpfile);
    if ($response->is_success) {

	my $file_length = (stat($tmpfile))[7];
	my($content_length) = $response->header('Content-length');

	if (defined $content_length and $file_length < $content_length) {
	    unlink($tmpfile);
	    die "Transfer truncated: " .
		"only $file_length out of $content_length bytes received\n";
	}
	elsif (defined $content_length and $file_length > $content_length) {
	    unlink($tmpfile);
	    die "Content-length mismatch: " .
		"expected $content_length bytes, got $file_length\n";
	}
	else {
	    # OK
	    if (-e $file) {
		# Some dosish systems fail to rename if the target exists
		chmod 0777, $file;
		unlink $file;
	    }
	    rename($tmpfile, $file) or
		die "Cannot rename '$tmpfile' to '$file': $!\n";

	    if (my $lm = $response->last_modified) {
		# make sure the file has the same last modification time
		utime $lm, $lm, $file;
	    }
	}
    }
    else {
	unlink($tmpfile);
    }
    return $response;
}


sub _need_proxy {
    my($req, $ua) = @_;
    return if exists $req->{proxy};
    my $proxy = $ua->{proxy}{$req->url->scheme} || return;
    if ($ua->{no_proxy}) {
        if (my $host = eval { $req->url->host }) {
            for my $domain (@{$ua->{no_proxy}}) {
                if ($host =~ /\Q$domain\E$/) {
                    return;
                }
            }
        }
    }
    $req->{proxy} = $HTTP::URI_CLASS->new($proxy);
}


sub proxy
{
    my $self = shift;
    my $key  = shift;
    return map $self->proxy($_, @_), @$key if ref $key;

    my $old = $self->{'proxy'}{$key};
    if (@_) {
        $self->{proxy}{$key} = shift;
        $self->set_my_handler("request_preprepare", \&_need_proxy)
    }
    return $old;
}


sub env_proxy {
    my ($self) = @_;
    my($k,$v);
    while(($k, $v) = each %ENV) {
	if ($ENV{REQUEST_METHOD}) {
	    # Need to be careful when called in the CGI environment, as
	    # the HTTP_PROXY variable is under control of that other guy.
	    next if $k =~ /^HTTP_/;
	    $k = "HTTP_PROXY" if $k eq "CGI_HTTP_PROXY";
	}
	$k = lc($k);
	next unless $k =~ /^(.*)_proxy$/;
	$k = $1;
	if ($k eq 'no') {
	    $self->no_proxy(split(/\s*,\s*/, $v));
	}
	else {
	    $self->proxy($k, $v);
	}
    }
}


sub no_proxy {
    my($self, @no) = @_;
    if (@no) {
	push(@{ $self->{'no_proxy'} }, @no);
    }
    else {
	$self->{'no_proxy'} = [];
    }
}


sub _new_response {
    my($request, $code, $message) = @_;
    my $response = HTTP::Response->new($code, $message);
    $response->request($request);
    $response->header("Client-Date" => HTTP::Date::time2str(time));
    $response->header("Client-Warning" => "Internal response");
    $response->header("Content-Type" => "text/plain");
    $response->content("$code $message\n");
    return $response;
}


1;

__END__

=head1 NAME

LWP::UserAgent - Web user agent class

=head1 SYNOPSIS

 require LWP::UserAgent;
 
 my $ua = LWP::UserAgent->new;
 $ua->timeout(10);
 $ua->env_proxy;
 
 my $response = $ua->get('http://search.cpan.org/');
 
 if ($response->is_success) {
     print $response->decoded_content;  # or whatever
 }
 else {
     die $response->status_line;
 }

=head1 DESCRIPTION

The C<LWP::UserAgent> is a class implementing a web user agent.
C<LWP::UserAgent> objects can be used to dispatch web requests.

In normal use the application creates an C<LWP::UserAgent> object, and
then configures it with values for timeouts, proxies, name, etc. It
then creates an instance of C<HTTP::Request> for the request that
needs to be performed. This request is then passed to one of the
request method the UserAgent, which dispatches it using the relevant
protocol, and returns a C<HTTP::Response> object.  There are
convenience methods for sending the most common request types: get(),
head() and post().  When using these methods then the creation of the
request object is hidden as shown in the synopsis above.

The basic approach of the library is to use HTTP style communication
for all protocol schemes.  This means that you will construct
C<HTTP::Request> objects and receive C<HTTP::Response> objects even
for non-HTTP resources like I<gopher> and I<ftp>.  In order to achieve
even more similarity to HTTP style communications, gopher menus and
file directories are converted to HTML documents.

=head1 CONSTRUCTOR METHODS

The following constructor methods are available:

=over 4

=item $ua = LWP::UserAgent->new( %options )

This method constructs a new C<LWP::UserAgent> object and returns it.
Key/value pair arguments may be provided to set up the initial state.
The following options correspond to attribute methods described below:

   KEY                     DEFAULT
   -----------             --------------------
   agent                   "libwww-perl/#.###"
   from                    undef
   conn_cache              undef
   cookie_jar              undef
   default_headers         HTTP::Headers->new
   max_size                undef
   max_redirect            7
   parse_head              1
   protocols_allowed       undef
   protocols_forbidden     undef
   requests_redirectable   ['GET', 'HEAD']
   timeout                 180

The following additional options are also accepted: If the
C<env_proxy> option is passed in with a TRUE value, then proxy
settings are read from environment variables (see env_proxy() method
below).  If the C<keep_alive> option is passed in, then a
C<LWP::ConnCache> is set up (see conn_cache() method below).  The
C<keep_alive> value is passed on as the C<total_capacity> for the
connection cache.

=item $ua->clone

Returns a copy of the LWP::UserAgent object.

=back

=head1 ATTRIBUTES

The settings of the configuration attributes modify the behaviour of the
C<LWP::UserAgent> when it dispatches requests.  Most of these can also
be initialized by options passed to the constructor method.

The following attributes methods are provided.  The attribute value is
left unchanged if no argument is given.  The return value from each
method is the old attribute value.

=over

=item $ua->agent

=item $ua->agent( $product_id )

Get/set the product token that is used to identify the user agent on
the network.  The agent value is sent as the "User-Agent" header in
the requests.  The default is the string returned by the _agent()
method (see below).

If the $product_id ends with space then the _agent() string is
appended to it.

The user agent string should be one or more simple product identifiers
with an optional version number separated by the "/" character.
Examples are:

  $ua->agent('Checkbot/0.4 ' . $ua->_agent);
  $ua->agent('Checkbot/0.4 ');    # same as above
  $ua->agent('Mozilla/5.0');
  $ua->agent("");                 # don't identify

=item $ua->_agent

Returns the default agent identifier.  This is a string of the form
"libwww-perl/#.###", where "#.###" is substituted with the version number
of this library.

=item $ua->from

=item $ua->from( $email_address )

Get/set the e-mail address for the human user who controls
the requesting user agent.  The address should be machine-usable, as
defined in RFC 822.  The C<from> value is send as the "From" header in
the requests.  Example:

  $ua->from('gaas@cpan.org');

The default is to not send a "From" header.  See the default_headers()
method for the more general interface that allow any header to be defaulted.

=item $ua->cookie_jar

=item $ua->cookie_jar( $cookie_jar_obj )

Get/set the cookie jar object to use.  The only requirement is that
the cookie jar object must implement the extract_cookies($request) and
add_cookie_header($response) methods.  These methods will then be
invoked by the user agent as requests are sent and responses are
received.  Normally this will be a C<HTTP::Cookies> object or some
subclass.

The default is to have no cookie_jar, i.e. never automatically add
"Cookie" headers to the requests.

Shortcut: If a reference to a plain hash is passed in as the
$cookie_jar_object, then it is replaced with an instance of
C<HTTP::Cookies> that is initialized based on the hash.  This form also
automatically loads the C<HTTP::Cookies> module.  It means that:

  $ua->cookie_jar({ file => "$ENV{HOME}/.cookies.txt" });

is really just a shortcut for:

  require HTTP::Cookies;
  $ua->cookie_jar(HTTP::Cookies->new(file => "$ENV{HOME}/.cookies.txt"));

=item $ua->default_headers

=item $ua->default_headers( $headers_obj )

Get/set the headers object that will provide default header values for
any requests sent.  By default this will be an empty C<HTTP::Headers>
object.

=item $ua->default_header( $field )

=item $ua->default_header( $field => $value )

This is just a short-cut for $ua->default_headers->header( $field =>
$value ). Example:

  $ua->default_header('Accept-Encoding' => scalar HTTP::Message::decodable());
  $ua->default_header('Accept-Language' => "no, en");

=item $ua->conn_cache

=item $ua->conn_cache( $cache_obj )

Get/set the C<LWP::ConnCache> object to use.  See L<LWP::ConnCache>
for details.

=item $ua->credentials( $netloc, $realm )

=item $ua->credentials( $netloc, $realm, $uname, $pass )

Get/set the user name and password to be used for a realm.

The $netloc is a string of the form "<host>:<port>".  The username and
password will only be passed to this server.  Example:

  $ua->credentials("www.example.com:80", "Some Realm", "foo", "secret");

=item $ua->max_size

=item $ua->max_size( $bytes )

Get/set the size limit for response content.  The default is C<undef>,
which means that there is no limit.  If the returned response content
is only partial, because the size limit was exceeded, then a
"Client-Aborted" header will be added to the response.  The content
might end up longer than C<max_size> as we abort once appending a
chunk of data makes the length exceed the limit.  The "Content-Length"
header, if present, will indicate the length of the full content and
will normally not be the same as C<< length($res->content) >>.

=item $ua->max_redirect

=item $ua->max_redirect( $n )

This reads or sets the object's limit of how many times it will obey
redirection responses in a given request cycle.

By default, the value is 7. This means that if you call request()
method and the response is a redirect elsewhere which is in turn a
redirect, and so on seven times, then LWP gives up after that seventh
request.

=item $ua->parse_head

=item $ua->parse_head( $boolean )

Get/set a value indicating whether we should initialize response
headers from the E<lt>head> section of HTML documents. The default is
TRUE.  Do not turn this off, unless you know what you are doing.

=item $ua->protocols_allowed

=item $ua->protocols_allowed( \@protocols )

This reads (or sets) this user agent's list of protocols that the
request methods will exclusively allow.  The protocol names are case
insensitive.

For example: C<$ua-E<gt>protocols_allowed( [ 'http', 'https'] );>
means that this user agent will I<allow only> those protocols,
and attempts to use this user agent to access URLs with any other
schemes (like "ftp://...") will result in a 500 error.

To delete the list, call: C<$ua-E<gt>protocols_allowed(undef)>

By default, an object has neither a C<protocols_allowed> list, nor a
C<protocols_forbidden> list.

Note that having a C<protocols_allowed> list causes any
C<protocols_forbidden> list to be ignored.

=item $ua->protocols_forbidden

=item $ua->protocols_forbidden( \@protocols )

This reads (or sets) this user agent's list of protocols that the
request method will I<not> allow. The protocol names are case
insensitive.

For example: C<$ua-E<gt>protocols_forbidden( [ 'file', 'mailto'] );>
means that this user agent will I<not> allow those protocols, and
attempts to use this user agent to access URLs with those schemes
will result in a 500 error.

To delete the list, call: C<$ua-E<gt>protocols_forbidden(undef)>

=item $ua->requests_redirectable

=item $ua->requests_redirectable( \@requests )

This reads or sets the object's list of request names that
C<$ua-E<gt>redirect_ok(...)> will allow redirection for.  By
default, this is C<['GET', 'HEAD']>, as per RFC 2616.  To
change to include 'POST', consider:

   push @{ $ua->requests_redirectable }, 'POST';

=item $ua->show_progress

=item $ua->show_progress( $boolean )

Get/set a value indicating whether a progress bar should be displayed
on on the terminal as requests are processed. The default is FALSE.

=item $ua->timeout

=item $ua->timeout( $secs )

Get/set the timeout value in seconds. The default timeout() value is
180 seconds, i.e. 3 minutes.

The requests is aborted if no activity on the connection to the server
is observed for C<timeout> seconds.  This means that the time it takes
for the complete transaction and the request() method to actually
return might be longer.

=back

=head2 Proxy attributes

The following methods set up when requests should be passed via a
proxy server.

=over

=item $ua->proxy(\@schemes, $proxy_url)

=item $ua->proxy($scheme, $proxy_url)

Set/retrieve proxy URL for a scheme:

 $ua->proxy(['http', 'ftp'], 'http://proxy.sn.no:8001/');
 $ua->proxy('gopher', 'http://proxy.sn.no:8001/');

The first form specifies that the URL is to be used for proxying of
access methods listed in the list in the first method argument,
i.e. 'http' and 'ftp'.

The second form shows a shorthand form for specifying
proxy URL for a single access scheme.

=item $ua->no_proxy( $domain, ... )

Do not proxy requests to the given domains.  Calling no_proxy without
any domains clears the list of domains. Eg:

 $ua->no_proxy('localhost', 'no', ...);

=item $ua->env_proxy

Load proxy settings from *_proxy environment variables.  You might
specify proxies like this (sh-syntax):

  gopher_proxy=http://proxy.my.place/
  wais_proxy=http://proxy.my.place/
  no_proxy="localhost,my.domain"
  export gopher_proxy wais_proxy no_proxy

csh or tcsh users should use the C<setenv> command to define these
environment variables.

On systems with case insensitive environment variables there exists a
name clash between the CGI environment variables and the C<HTTP_PROXY>
environment variable normally picked up by env_proxy().  Because of
this C<HTTP_PROXY> is not honored for CGI scripts.  The
C<CGI_HTTP_PROXY> environment variable can be used instead.

=back

=head2 Handlers

Handlers are code that injected at various phases during the
processing of requests.  The following methods are provided to manage
the active handlers:

=over

=item $ua->add_handler( $phase => \&cb, %matchspec )

Add handler to be invoked in the given processing phase.  For how to
specify %matchspec see L<HTTP::Config/"Matching">.

The possible values $phase and the corresponding callback signatures are:

=over

=item request_preprepare => sub { my($request, $ua, $h) = @_; ... }

The handler is called before the C<request_prepare> and other standard
initialization of of the request.  This can be used to set up headers
and attributes that the C<request_prepare> handler depends on.  Proxy
initialization should take place here; but in general don't register
handlers for this phase.

=item request_prepare => sub { my($request, $ua, $h) = @_; ... }

The handler is called before the request is sent and can modify the
request any way it see hit.  This can for instance be used to add
certain headers to specific requests.

The method can assign a new request object to $_[0] to replace the
request that is sent fully.

The return value from the callback is ignored.  Exceptions are
not trapped and are propagated to the outer request method.

=item request_send => sub { my($request, $ua, $h) = @_; ... }

This handler get a chance of handling requests before it's sent to the
protocol handlers.  It should return an HTTP::Response object if it
wishes to terminate the processing; otherwise it should return nothing.

The C<response_header> and C<response_data> handlers will not be
invoked for this response, but the C<response_done> will be.

=item response_header => sub { my($response, $ua, $h) = @_; ... }

This handler is called right after the response headers have been
received, but before any content data.  The handler might set up
handlers for data and might croak to abort the request.

The handler might set the $response->{default_add_content} value to
control if any received data should be added to the response object
directly.  This will initially be false if the $ua->request() method
was called with a ':content_filename' or ':content_callbak' argument;
otherwise true.

=item response_data => sub { my($response, $ua, $h, $data) = @_; ... }

This handlers is called for each chunk of data received for the
response.  The handler might croak to abort the request.

This handler need to return a TRUE value to be called again for
subsequent chunks for the same request.

=item response_done => sub { my($response, $ua, $h) = @_; ... }

The handler is called after the response has been fully received, but
before any redirect handling is attempted.  The handler can be used to
extract information or modify the response.

=item response_redirect => sub { my($response, $ua, $h) = @_; ... }

The handler is called in $ua->request after C<response_done>.  If the
handler return an HTTP::Request object we'll start over with processing
this request instead.

=back

=item $ua->remove_handler( undef, %matchspec )

=item $ua->remove_handler( $phase, %matchspec )

Remove handlers that match the given %matchspec.  If $phase is not
provided remove handlers from all phases.

Be careful as calling this function with %matchspec that is not not
specific enough can remove handlers not owned by you.  It's probably
better to use the set_my_handler() method instead.

The removed handlers are returned.

=item $ua->set_my_handler( $phase, $cb, %matchspec )

Set handlers private to the executing subroutine.  Works by defaulting
an C<owner> field to the %matchhspec that holds the name of the called
subroutine.  You might pass an explicit C<owner> to override this.

If $cb is passed as C<undef>, remove the handler.

=item $ua->get_my_handler( $phase, %matchspec )

=item $ua->get_my_handler( $phase, %matchspec, $init )

The retrieve the matching handler as hash ref.

If C<$init> is passed passed as a TRUE value, create and add the
handler if it's not found.  If $init is a subroutine reference, then
it's called with the created handler hash as argument.  This sub might
populate the hash with extra fields; especially the callback.  If
$init is a hash reference, merge the hashes.

=item $ua->handlers( $phase, $request )

=item $ua->handlers( $phase, $response )

Returns the handlers that apply to the given request or response at
the given processing phase.

=back

=head1 REQUEST METHODS

The methods described in this section are used to dispatch requests
via the user agent.  The following request methods are provided:

=over

=item $ua->get( $url )

=item $ua->get( $url , $field_name => $value, ... )

This method will dispatch a C<GET> request on the given $url.  Further
arguments can be given to initialize the headers of the request. These
are given as separate name/value pairs.  The return value is a
response object.  See L<HTTP::Response> for a description of the
interface it provides.

Fields names that start with ":" are special.  These will not
initialize headers of the request but will determine how the response
content is treated.  The following special field names are recognized:

    :content_file   => $filename
    :content_cb     => \&callback
    :read_size_hint => $bytes

If a $filename is provided with the C<:content_file> option, then the
response content will be saved here instead of in the response
object.  If a callback is provided with the C<:content_cb> option then
this function will be called for each chunk of the response content as
it is received from the server.  If neither of these options are
given, then the response content will accumulate in the response
object itself.  This might not be suitable for very large response
bodies.  Only one of C<:content_file> or C<:content_cb> can be
specified.  The content of unsuccessful responses will always
accumulate in the response object itself, regardless of the
C<:content_file> or C<:content_cb> options passed in.

The C<:read_size_hint> option is passed to the protocol module which
will try to read data from the server in chunks of this size.  A
smaller value for the C<:read_size_hint> will result in a higher
number of callback invocations.

The callback function is called with 3 arguments: a chunk of data, a
reference to the response object, and a reference to the protocol
object.  The callback can abort the request by invoking die().  The
exception message will show up as the "X-Died" header field in the
response returned by the get() function.

=item $ua->head( $url )

=item $ua->head( $url , $field_name => $value, ... )

This method will dispatch a C<HEAD> request on the given $url.
Otherwise it works like the get() method described above.

=item $ua->post( $url, \%form )

=item $ua->post( $url, \@form )

=item $ua->post( $url, \%form, $field_name => $value, ... )

=item $ua->post( $url, $field_name => $value,... Content => \%form )

=item $ua->post( $url, $field_name => $value,... Content => \@form )

=item $ua->post( $url, $field_name => $value,... Content => $content )

This method will dispatch a C<POST> request on the given $url, with
%form or @form providing the key/value pairs for the fill-in form
content. Additional headers and content options are the same as for
the get() method.

This method will use the POST() function from C<HTTP::Request::Common>
to build the request.  See L<HTTP::Request::Common> for a details on
how to pass form content and other advanced features.

=item $ua->mirror( $url, $filename )

This method will get the document identified by $url and store it in
file called $filename.  If the file already exists, then the request
will contain an "If-Modified-Since" header matching the modification
time of the file.  If the document on the server has not changed since
this time, then nothing happens.  If the document has been updated, it
will be downloaded again.  The modification time of the file will be
forced to match that of the server.

The return value is the the response object.

=item $ua->request( $request )

=item $ua->request( $request, $content_file )

=item $ua->request( $request, $content_cb )

=item $ua->request( $request, $content_cb, $read_size_hint )

This method will dispatch the given $request object.  Normally this
will be an instance of the C<HTTP::Request> class, but any object with
a similar interface will do.  The return value is a response object.
See L<HTTP::Request> and L<HTTP::Response> for a description of the
interface provided by these classes.

The request() method will process redirects and authentication
responses transparently.  This means that it may actually send several
simple requests via the simple_request() method described below.

The request methods described above; get(), head(), post() and
mirror(), will all dispatch the request they build via this method.
They are convenience methods that simply hides the creation of the
request object for you.

The $content_file, $content_cb and $read_size_hint all correspond to
options described with the get() method above.

You are allowed to use a CODE reference as C<content> in the request
object passed in.  The C<content> function should return the content
when called.  The content can be returned in chunks.  The content
function will be invoked repeatedly until it return an empty string to
signal that there is no more content.

=item $ua->simple_request( $request )

=item $ua->simple_request( $request, $content_file )

=item $ua->simple_request( $request, $content_cb )

=item $ua->simple_request( $request, $content_cb, $read_size_hint )

This method dispatches a single request and returns the response
received.  Arguments are the same as for request() described above.

The difference from request() is that simple_request() will not try to
handle redirects or authentication responses.  The request() method
will in fact invoke this method for each simple request it sends.

=item $ua->is_protocol_supported( $scheme )

You can use this method to test whether this user agent object supports the
specified C<scheme>.  (The C<scheme> might be a string (like 'http' or
'ftp') or it might be an URI object reference.)

Whether a scheme is supported, is determined by the user agent's
C<protocols_allowed> or C<protocols_forbidden> lists (if any), and by
the capabilities of LWP.  I.e., this will return TRUE only if LWP
supports this protocol I<and> it's permitted for this particular
object.

=back

=head2 Callback methods

The following methods will be invoked as requests are processed. These
methods are documented here because subclasses of C<LWP::UserAgent>
might want to override their behaviour.

=over

=item $ua->prepare_request( $request )

This method is invoked by simple_request().  Its task is to modify the
given $request object by setting up various headers based on the
attributes of the user agent. The return value should normally be the
$request object passed in.  If a different request object is returned
it will be the one actually processed.

The headers affected by the base implementation are; "User-Agent",
"From", "Range" and "Cookie".

=item $ua->redirect_ok( $prospective_request, $response )

This method is called by request() before it tries to follow a
redirection to the request in $response.  This should return a TRUE
value if this redirection is permissible.  The $prospective_request
will be the request to be sent if this method returns TRUE.

The base implementation will return FALSE unless the method
is in the object's C<requests_redirectable> list,
FALSE if the proposed redirection is to a "file://..."
URL, and TRUE otherwise.

=item $ua->get_basic_credentials( $realm, $uri, $isproxy )

This is called by request() to retrieve credentials for documents
protected by Basic or Digest Authentication.  The arguments passed in
is the $realm provided by the server, the $uri requested and a boolean
flag to indicate if this is authentication against a proxy server.

The method should return a username and password.  It should return an
empty list to abort the authentication resolution attempt.  Subclasses
can override this method to prompt the user for the information. An
example of this can be found in C<lwp-request> program distributed
with this library.

The base implementation simply checks a set of pre-stored member
variables, set up with the credentials() method.

=item $ua->progress( $status, $request_or_response )

This is called frequently as the response is received regardless of
how the content is processed.  The method is called with $status
"begin" at the start of processing the request and with $state "end"
before the request method returns.  In between these $status will be
the fraction of the response currently received or the string "tick"
if the fraction can't be calculated.

When $status is "begin" the second argument is the request object,
otherwise it is the response object.

=back

=head1 SEE ALSO

See L<LWP> for a complete overview of libwww-perl5.  See L<lwpcook>
and the scripts F<lwp-request> and F<lwp-download> for examples of
usage.

See L<HTTP::Request> and L<HTTP::Response> for a description of the
message objects dispatched and received.  See L<HTTP::Request::Common>
and L<HTML::Form> for other ways to build request objects.

See L<WWW::Mechanize> and L<WWW::Search> for examples of more
specialized user agents based on C<LWP::UserAgent>.

=head1 COPYRIGHT

Copyright 1995-2008 Gisle Aas.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

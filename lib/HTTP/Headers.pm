package HTTP::Headers;

# $Id: Headers.pm,v 1.44 2002/06/29 00:41:29 gisle Exp $

=head1 NAME

HTTP::Headers - Class encapsulating HTTP Message headers

=head1 SYNOPSIS

 require HTTP::Headers;
 $h = HTTP::Headers->new;

 $h->header('Content-Type' => 'text/plain');  # set
 $ct = $h->header('Content-Type');            # get
 $h->remove_header('Content-Type');           # delete

=head1 DESCRIPTION

The C<HTTP::Headers> class encapsulates HTTP-style message headers.
The headers consist of attribute-value pairs also called fields, which
may be repeated, and which are printed in a particular order.

Instances of this class are usually created as member variables of the
C<HTTP::Request> and C<HTTP::Response> classes, internal to the
library.

The following methods are available:

=over 4

=cut

use strict;
use Carp ();

use vars qw($VERSION $TRANSLATE_UNDERSCORE);
$VERSION = sprintf("%d.%02d", q$Revision: 1.44 $ =~ /(\d+)\.(\d+)/);

# The $TRANSLATE_UNDERSCORE variable controls whether '_' can be used
# as a replacement for '-' in header field names.
$TRANSLATE_UNDERSCORE = 1 unless defined $TRANSLATE_UNDERSCORE;

# "Good Practice" order of HTTP message headers:
#    - General-Headers
#    - Request-Headers
#    - Response-Headers
#    - Entity-Headers

my @header_order = qw(
   Cache-Control Connection Date Pragma Trailer Transfer-Encoding Upgrade
   Via Warning

   Accept Accept-Charset Accept-Encoding Accept-Language
   Authorization Expect From Host
   If-Match If-Modified-Since If-None-Match If-Range If-Unmodified-Since
   Max-Forwards Proxy-Authorization Range Referer TE User-Agent

   Accept-Ranges Age ETag Location Proxy-Authenticate Retry-After Server
   Vary WWW-Authenticate

   Allow Content-Encoding Content-Language Content-Length Content-Location
   Content-MD5 Content-Range Content-Type Expires Last-Modified
);

# Make alternative representations of @header_order.  This is used
# for sorting and case matching.
my %header_order;
my %standard_case;

{
    my $i = 0;
    for (@header_order) {
	my $lc = lc $_;
	$header_order{$lc} = ++$i;
	$standard_case{$lc} = $_;
    }
}




=item $h = HTTP::Headers->new

Constructs a new C<HTTP::Headers> object.  You might pass some initial
attribute-value pairs as parameters to the constructor.  I<E.g.>:

 $h = HTTP::Headers->new(
       Date         => 'Thu, 03 Feb 1994 00:00:00 GMT',
       Content_Type => 'text/html; version=3.2',
       Content_Base => 'http://www.perl.org/');

The constructor arguments are passed to the C<header> method which is
described below.

=cut

sub new
{
    my($class) = shift;
    my $self = bless {}, $class;
    $self->header(@_); # set up initial headers
    $self;
}


=item $h->header($field [=> $value],...)

Get or set the value of one or more header fields.  The header field name
($field) is not case sensitive.  To make the life easier for perl
users who wants to avoid quoting before the => operator, you can use
'_' as a replacement for '-' in header names (this behaviour can be
suppressed by setting the $HTTP::Headers::TRANSLATE_UNDERSCORE
variable to a FALSE value).

The header() method accepts multiple ($field => $value) pairs, which
means that you can update several fields with a single invocation.

The $value argument may be a plain string or a reference to an array
of strings for a multi-valued field. If the $value is undefined or not
given, then that header field will remain unchanged.

The old value (or values) of the last of the header fields is returned.
If no such field exists C<undef> will be returned.

A multi-valued field will be retuned as separate values in list
context and will be concatenated with ", " as separator in scalar
context.  The HTTP spec (RFC 2616) promise that joining multiple
values in this way will not change the semantic of a header field, but
in practice there are cases like old-style Netscape cookies (see
L<HTTP::Cookies>) where "," is used as part of the syntax of a single
field value.

Examples:

 $header->header(MIME_Version => '1.0',
		 User_Agent   => 'My-Web-Client/0.01');
 $header->header(Accept => "text/html, text/plain, image/*");
 $header->header(Accept => [qw(text/html text/plain image/*)]);
 @accepts = $header->header('Accept');  # get multiple values
 $accepts = $header->header('Accept');  # get values as a single string

=cut

sub header
{
    my $self = shift;
    my(@old);
    while (my($field, $val) = splice(@_, 0, 2)) {
	@old = $self->_header($field, $val);
    }
    return @old if wantarray;
    return $old[0] if @old <= 1;
    join(", ", @old);
}


=item $h->push_header($field, $value)

Add a new field value for the specified header field.  Previous values
for the same field are retained.

As for the header() method, the field name ($field) is not case
sensitive and '_' can be used as a replacement for '-'.

The $value argument may be a scalar or a reference to a list of
scalars.

 $header->push_header(Accept => 'image/jpeg');
 $header->push_header(Accept => [map "image/$_", qw(gif png tiff)]);

=cut

sub push_header
{
    Carp::croak('Usage: $h->push_header($field, $val)') if @_ != 3;
    shift->_header(@_, 'PUSH');
}

=item $h->init_header($field, $value)

Set the specified header to the given value, but only if no previous
value for that field is set.

The header field name ($field) is not case sensitive and '_'
can be used as a replacement for '-'.

The $value argument may be a scalar or a reference to a list of
scalars.

=cut

sub init_header
{
    Carp::croak('Usage: $h->init_header($field, $val)') if @_ != 3;
    shift->_header(@_, 'INIT');
}


=item $h->remove_header($field,...)

This function removes the headers fields with the specified names.

The header field names ($field) are not case sensitive and '_'
can be used as a replacement for '-'.

The return value is the values of the fields removed.  In scalar
context the number of fields removed is returned.

Note that if you pass in multiple field names then it is generally not
possible to tell which of the returned values belonged to which field.

=cut

sub remove_header
{
    my($self, @fields) = @_;
    my $field;
    my @values;
    foreach $field (@fields) {
	$field =~ tr/_/-/ if $TRANSLATE_UNDERSCORE;
	my $v = delete $self->{lc $field};
	push(@values, ref($v) eq 'ARRAY' ? @$v : $v) if defined $v;
    }
    return @values;
}


sub _header
{
    my($self, $field, $val, $op) = @_;
    $field =~ tr/_/-/ if $TRANSLATE_UNDERSCORE;

    # $push is only used interally sub push_header
    Carp::croak('Need a field name') unless length($field);

    my $lc_field = lc $field;
    unless(defined $standard_case{$lc_field}) {
	# generate a %standard_case entry for this field
	$field =~ s/\b(\w)/\u$1/g;
	$standard_case{$lc_field} = $field;
    }

    my $h = $self->{$lc_field};
    my @old = ref($h) eq 'ARRAY' ? @$h : (defined($h) ? ($h) : ());

    $op ||= "";
    $val = undef if $op eq 'INIT' && @old;
    if (defined($val)) {
	my @new = ($op eq 'PUSH') ? @old : ();
	if (ref($val) ne 'ARRAY') {
	    push(@new, $val);
	}
	else {
	    push(@new, @$val);
	}
	$self->{$lc_field} = @new > 1 ? \@new : $new[0];
    }
    @old;
}


# Compare function which makes it easy to sort headers in the
# recommended "Good Practice" order.
sub _header_cmp
{
    ($header_order{$a} || 999) <=> ($header_order{$b} || 999) || $a cmp $b;
}


=item $h->scan(\&doit)

Apply a subroutine to each header field in turn.  The callback routine
is called with two parameters; the name of the field and a single
value (a string).  If a header field is multi-valued, then the
routine is called once for each value.  The field name passed to the
callback routine has case as suggested by HTTP spec, and the headers
will be visited in the recommended "Good Practice" order.

Any return values of the callback routine are ignored.  The loop can
be broken by raising an exception (C<die>).

=cut

sub scan
{
    my($self, $sub) = @_;
    my $key;
    foreach $key (sort _header_cmp keys %$self) {
        next if $key =~ /^_/;
	my $vals = $self->{$key};
	if (ref($vals) eq 'ARRAY') {
	    my $val;
	    for $val (@$vals) {
		&$sub($standard_case{$key} || $key, $val);
	    }
	} else {
	    &$sub($standard_case{$key} || $key, $vals);
	}
    }
}


=item $h->as_string([$endl])

Return the header fields as a formatted MIME header.  Since it
internally uses the C<scan> method to build the string, the result
will use case as suggested by HTTP spec, and it will follow
recommended "Good Practice" of ordering the header fieds.  Long header
values are not folded.

The optional $endl parameter specifies the line ending sequence to
use.  The default is "\n".  Embedded "\n" characters in header field
values will be substitued with this line ending sequence.

=cut

sub as_string
{
    my($self, $endl) = @_;
    $endl = "\n" unless defined $endl;

    my @result = ();
    $self->scan(sub {
	my($field, $val) = @_;
	if ($val =~ /\n/) {
	    # must handle header values with embedded newlines with care
	    $val =~ s/\s+$//;          # trailing newlines and space must go
	    $val =~ s/\n\n+/\n/g;      # no empty lines
	    $val =~ s/\n([^\040\t])/\n $1/g;  # intial space for continuation
	    $val =~ s/\n/$endl/g;      # substitute with requested line ending
	}
	push(@result, "$field: $val");
    });

    join($endl, @result, '');
}


=item $h->clone

Returns a copy of this C<HTTP::Headers> object.

=back

=cut

sub clone
{
    my $self = shift;
    my $clone = new HTTP::Headers;
    $self->scan(sub { $clone->push_header(@_);} );
    $clone;
}


=head1 CONVENIENCE METHODS

The most frequently used headers can also be accessed through the
following convenience methods.  These methods can both be used to read
and to set the value of a header.  The header value is set if you pass
an argument to the method.  The old header value is always returned.
If the given header did not exists then C<undef> is returned.

Methods that deal with dates/times always convert their value to system
time (seconds since Jan 1, 1970) and they also expect this kind of
value when the header value is set.

=over 4

=item $h->date

This header represents the date and time at which the message was
originated. I<E.g.>:

  $h->date(time);  # set current date

=item $h->expires

This header gives the date and time after which the entity should be
considered stale.

=item $h->if_modified_since

=item $h->if_unmodified_since

These header fields are used to make a request conditional.  If the requested
resource has (or has not) been modified since the time specified in this field,
then the server will return a C<304 Not Modified> response instead of
the document itself.

=item $h->last_modified

This header indicates the date and time at which the resource was last
modified. I<E.g.>:

  # check if document is more than 1 hour old
  if (my $last_mod = $h->last_modified) {
      if ($last_mod < time - 60*60) {
	  ...
      }
  }

=item $h->content_type

The Content-Type header field indicates the media type of the message
content. I<E.g.>:

  $h->content_type('text/html');

The value returned will be converted to lower case, and potential
parameters will be chopped off and returned as a separate value if in
an array context.  This makes it safe to do the following:

  if ($h->content_type eq 'text/html') {
     # we enter this place even if the real header value happens to
     # be 'TEXT/HTML; version=3.0'
     ...
  }

=item $h->content_encoding

The Content-Encoding header field is used as a modifier to the
media type.  When present, its value indicates what additional
encoding mechanism has been applied to the resource.

=item $h->content_length

A decimal number indicating the size in bytes of the message content.

=item $h->content_language

The natural language(s) of the intended audience for the message
content.  The value is one or more language tags as defined by RFC
1766.  Eg. "no" for some kind of Norwegian and "en-US" for English the
way it is written in the US.

=item $h->title

The title of the document.  In libwww-perl this header will be
initialized automatically from the E<lt>TITLE>...E<lt>/TITLE> element
of HTML documents.  I<This header is no longer part of the HTTP
standard.>

=item $h->user_agent

This header field is used in request messages and contains information
about the user agent originating the request.  I<E.g.>:

  $h->user_agent('Mozilla/1.2');

=item $h->server

The server header field contains information about the software being
used by the originating server program handling the request.

=item $h->from

This header should contain an Internet e-mail address for the human
user who controls the requesting user agent.  The address should be
machine-usable, as defined by RFC822.  E.g.:

  $h->from('King Kong <king@kong.com>');

I<This header is no longer part of the HTTP standard.>

=item $h->referer

Used to specify the address (URI) of the document from which the
requested resouce address was obtained.

The "Free On-line Dictionary of Computing" as this to say about the
word I<referer>:

     <World-Wide Web> A misspelling of "referrer" which
     somehow made it into the {HTTP} standard.  A given {web
     page}'s referer (sic) is the {URL} of whatever web page
     contains the link that the user followed to the current
     page.  Most browsers pass this information as part of a
     request.

     (1998-10-19)

By popular demand C<referrer> exists as an alias for this method so you
can avoid this misspelling in your programs and still send the right
thing on the wire.


=item $h->www_authenticate

This header must be included as part of a C<401 Unauthorized> response.
The field value consist of a challenge that indicates the
authentication scheme and parameters applicable to the requested URI.

=item $h->proxy_authenticate

This header must be included in a C<407 Proxy Authentication Required>
response.

=item $h->authorization

=item $h->proxy_authorization

A user agent that wishes to authenticate itself with a server or a
proxy, may do so by including these headers.

=item $h->authorization_basic

This method is used to get or set an authorization header that use the
"Basic Authentication Scheme".  In array context it will return two
values; the user name and the password.  In scalar context it will
return I<"uname:password"> as a single string value.

When used to set the header value, it expects two arguments.  I<E.g.>:

  $h->authorization_basic($uname, $password);

The method will croak if the $uname contains a colon ':'.

=item $h->proxy_authorization_basic

Same as authorization_basic() but will set the "Proxy-Authorization"
header instead.

=back

=cut

sub _date_header
{
    require HTTP::Date;
    my($self, $header, $time) = @_;
    my($old) = $self->_header($header);
    if (defined $time) {
	$self->_header($header, HTTP::Date::time2str($time));
    }
    HTTP::Date::str2time($old);
}

sub date                { shift->_date_header('Date',                @_); }
sub expires             { shift->_date_header('Expires',             @_); }
sub if_modified_since   { shift->_date_header('If-Modified-Since',   @_); }
sub if_unmodified_since { shift->_date_header('If-Unmodified-Since', @_); }
sub last_modified       { shift->_date_header('Last-Modified',       @_); }

# This is used as a private LWP extention.  The Client-Date header is
# added as a timestamp to a response when it has been received.
sub client_date         { shift->_date_header('Client-Date',         @_); }

# The retry_after field is dual format (can also be a expressed as
# number of seconds from now), so we don't provide an easy way to
# access it until we have know how both these interfaces can be
# addressed.  One possibility is to return a negative value for
# relative seconds and a positive value for epoch based time values.
#sub retry_after       { shift->_date_header('Retry-After',       @_); }

sub content_type      {
  my $ct = (shift->_header('Content-Type', @_))[0];
  return '' unless defined($ct) && length($ct);
  my @ct = split(/\s*;\s*/, lc($ct));
  wantarray ? @ct : $ct[0];
}

sub title             { (shift->_header('Title',            @_))[0] }
sub content_encoding  { (shift->_header('Content-Encoding', @_))[0] }
sub content_language  { (shift->_header('Content-Language', @_))[0] }
sub content_length    { (shift->_header('Content-Length',   @_))[0] }

sub user_agent        { (shift->_header('User-Agent',       @_))[0] }
sub server            { (shift->_header('Server',           @_))[0] }

sub from              { (shift->_header('From',             @_))[0] }
sub referer           { (shift->_header('Referer',          @_))[0] }
*referrer = \&referer;  # on tchrist's request
sub warning           { (shift->_header('Warning',          @_))[0] }

sub www_authenticate  { (shift->_header('WWW-Authenticate', @_))[0] }
sub authorization     { (shift->_header('Authorization',    @_))[0] }

sub proxy_authenticate  { (shift->_header('Proxy-Authenticate',  @_))[0] }
sub proxy_authorization { (shift->_header('Proxy-Authorization', @_))[0] }

sub authorization_basic       { shift->_basic_auth("Authorization",       @_) }
sub proxy_authorization_basic { shift->_basic_auth("Proxy-Authorization", @_) }

sub _basic_auth {
    require MIME::Base64;
    my($self, $h, $user, $passwd) = @_;
    my($old) = $self->_header($h);
    if (defined $user) {
	Carp::croak("Basic authorization user name can't contain ':'")
	  if $user =~ /:/;
	$passwd = '' unless defined $passwd;
	$self->_header($h => 'Basic ' .
                             MIME::Base64::encode("$user:$passwd", ''));
    }
    if (defined $old && $old =~ s/^\s*Basic\s+//) {
	my $val = MIME::Base64::decode($old);
	return $val unless wantarray;
	return split(/:/, $val, 2);
    }
    return;
}

=head1 COPYRIGHT

Copyright 1995-2002 Gisle Aas.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

1;

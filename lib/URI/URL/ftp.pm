package URI::URL::ftp;
require URI::URL::_generic;
@ISA = qw(URI::URL::_generic);

sub default_port { 21 }

sub _parse {
    my($self, $init) = @_;
    # The ftp URLs can't have any query string
    $self->URI::URL::_generic::_parse($init, qw(netloc path params frag));
    1;
}


sub user
{
    my($self, @val) = @_;
    my $old = $self->SUPER::user(@val);
    defined $old ? $old : "anonymous";
}

BEGIN {
    $whoami = undef;
    $fqdn   = undef;
}

sub password
{
    my($self, @val) = @_;
    my $old = $self->SUPER::password(@val);
    unless (defined $old) {
	my $user = $self->user;
	if ($user eq 'anonymous' || $user eq 'ftp') {
	    # anonymous ftp login password
	    unless (defined $fqdn) {
		require Sys::Hostname;
		$fqdn = Sys::Hostname::hostname();
	    }
	    unless (defined $whoami) {
		$whoami = $ENV{USER} || $ENV{LOGNAME};
		unless ($whoami) {
		    chomp($whoami = `whoami`);
		}
	    }
	    $old = "$whoami\@$fqdn";
	} else {
	    $old = "";
	}
    }
    $old;
}

*query  = \&URI::URL::bad_method;
*equery = \&URI::URL::bad_method;

1;

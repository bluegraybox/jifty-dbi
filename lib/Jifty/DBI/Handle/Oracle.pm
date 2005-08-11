package Jifty::DBI::Handle::Oracle;
use base qw/Jifty::DBI::Handle/;
use DBD::Oracle qw(:ora_types);

use vars qw($VERSION $DBIHandle $DEBUG);

=head1 NAME

  Jifty::DBI::Handle::Oracle - An oracle specific Handle object

=head1 SYNOPSIS

=head1 DESCRIPTION

This module provides a subclass of L<Jifty::DBI::Handle> that
compensates for some of the idiosyncrasies of Oracle.

=head1 METHODS

=head2 connect PARAMHASH: Driver, Database, Host, User, Password

Takes a paramhash and connects to your DBI datasource. 

=cut

sub connect {
    my $self = shift;

    my %args = (
        Driver   => undef,
        Database => undef,
        User     => undef,
        Password => undef,
        SID      => undef,
        Host     => undef,
        @_
    );

    $self->SUPER::connect(%args);

    $self->dbh->{LongTruncOk} = 1;
    $self->dbh->{LongReadLen} = 8000;

    $self->simple_query(
        "ALTER SESSION set NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'");

    return ($DBIHandle);
}

=head2 insert

Takes a table name as the first argument and assumes that the rest of
the arguments are an array of key-value pairs to be inserted.

=cut

sub insert {
    my $self  = shift;
    my $table = shift;
    my ($sth);

    # Oracle Hack to replace non-supported mysql_rowid call

    my %attribs = @_;
    my ( $unique_id, $QueryString );

    if ( $attribs{'Id'} || $attribs{'id'} ) {
        $unique_id = ( $attribs{'Id'} ? $attribs{'Id'} : $attribs{'id'} );
    }
    else {

        $QueryString = "SELECT " . $table . "_seq.nextval FROM DUAL";

        $sth = $self->simple_query($QueryString);
        if ( !$sth ) {
            if ($main::debug) {
                die "Error with $QueryString";
            }
            else {
                return (undef);
            }
        }

        #needs error checking
        my @row = $sth->fetchrow_array;

        $unique_id = $row[0];

    }

    #TODO: don't hardcode this to id pull it from somewhere else
    #call super::insert with the new column id.

    $attribs{'id'} = $unique_id;
    delete $attribs{'Id'};
    $sth = $self->SUPER::insert( $table, %attribs );

    unless ($sth) {
        if ($main::debug) {
            die "Error with $QueryString: " . $self->dbh->errstr;
        }
        else {
            return (undef);
        }
    }

    $self->{'id'} = $unique_id;
    return ( $self->{'id'} );    #Add Succeded. return the id
}

=head2  build_dsn PARAMHASH

Takes a bunch of parameters:  

Required: Driver, Database or Host/SID,
Optional: Port and RequireSSL

Builds a DSN suitable for an Oracle DBI connection

=cut

sub build_dsn {
    my $self = shift;
    my %args = (
        Driver     => undef,
        Database   => undef,
        Host       => undef,
        Port       => undef,
        SID        => undef,
        RequireSSL => undef,
        @_
    );

    my $dsn = "dbi:$args{'Driver'}:";

    if (   defined $args{'Host'}
        && $args{'Host'}
        && defined $args{'SID'}
        && $args{'SID'} )
    {
        $dsn .= "host=$args{'Host'};sid=$args{'SID'}";
    }
    else {
        $dsn .= "$args{'Database'}"
            if ( defined $args{'Database'} && $args{'Database'} );
    }
    $dsn .= ";port=$args{'Port'}"
        if ( defined $args{'Port'} && $args{'Port'} );
    $dsn .= ";requiressl=1"
        if ( defined $args{'RequireSSL'} && $args{'RequireSSL'} );

    $self->{'dsn'} = $dsn;
}

=head2 knows_blobs     

Returns 1 if the current database supports inserts of BLOBs
automatically.  Returns undef if the current database must be informed
of BLOBs for inserts.

=cut

sub knows_blobs {
    my $self = shift;
    return (undef);
}

=head2 blob_params FIELD_NAME FIELD_TYPE

Returns a hash ref for the bind_param call to identify BLOB types used
by the current database for a particular column type.  The current
Oracle implementation only supports ORA_CLOB types (112).

=cut

sub blob_params {
    my $self  = shift;
    my $field = shift;

    #my $type = shift;
    # Don't assign to key 'value' as it is defined later.
    return (
        {   ora_field => $field,
            ora_type  => ORA_CLOB,
        }
    );
}

=head2 apply_limits STATEMENTREF ROWS_PER_PAGE FIRST_ROW

takes an SQL SELECT statement and massages it to return ROWS_PER_PAGE
starting with FIRST_ROW;

=cut

sub apply_limits {
    my $self         = shift;
    my $statementref = shift;
    my $per_page     = shift;
    my $first        = shift;

    # Transform an SQL query from:
    #
    # SELECT main.*
    #   FROM Tickets main
    #  WHERE ((main.EffectiveId = main.id))
    #    AND ((main.Type = 'ticket'))
    #    AND ( ( (main.Status = 'new')OR(main.Status = 'open') )
    #    AND ( (main.Queue = '1') ) )
    #
    # to:
    #
    # SELECT * FROM (
    #     SELECT limitquery.*,rownum limitrownum FROM (
    #             SELECT main.*
    #               FROM Tickets main
    #              WHERE ((main.EffectiveId = main.id))
    #                AND ((main.Type = 'ticket'))
    #                AND ( ( (main.Status = 'new')OR(main.Status = 'open') )
    #                AND ( (main.Queue = '1') ) )
    #     ) limitquery WHERE rownum <= 50
    # ) WHERE limitrownum >= 1
    #

    if ($per_page) {

        # Oracle orders from 1 not zero
        $first++;

        # Make current query a sub select
        $$statementref
            = "SELECT * FROM ( SELECT limitquery.*,rownum limitrownum FROM ( $$statementref ) limitquery WHERE rownum <= "
            . ( $first + $per_page - 1 )
            . " ) WHERE limitrownum >= "
            . $first;
    }
}

=head2 distinct_query STATEMENTREF

takes an incomplete SQL SELECT statement and massages it to return a
DISTINCT result set.

=cut

sub distinct_query {
    my $self         = shift;
    my $statementref = shift;
    my $table        = shift;

    # Wrapper select query in a subselect as Oracle doesn't allow
    # DISTINCT against CLOB/BLOB column types.
    $$statementref
        = "SELECT main.* FROM ( SELECT DISTINCT main.id FROM $$statementref ) distinctquery, $table main WHERE (main.id = distinctquery.id) ";

}

=head2 binary_safe_blobs

Return undef, as Oracle doesn't support binary-safe CLOBS

=cut

sub binary_safe_blobs {
    my $self = shift;
    return (undef);
}

1;

__END__

=head1 AUTHOR

Jesse Vincent, jesse@fsck.com

=head1 SEE ALSO

L<Jifty::DBI>, L<Jifty::DBI::Handle>, L<DBD::Oracle>

=cut
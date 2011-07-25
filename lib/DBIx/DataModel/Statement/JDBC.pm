#----------------------------------------------------------------------
package DBIx::DataModel::Statement::JDBC;
#----------------------------------------------------------------------
use base qw/DBIx::DataModel::Statement/;
use DBI  qw/SQL_INTEGER/;


# methods on the JDBC ResultSet object, without argument
foreach my $method (qw/size           getRow
                       getMemberCount getSQLStatement 
                       beforeFirst    afterLast
                       isBeforeFirst  isAfterLast/) {
  *{$method} = sub {
    my ($self) = @_;
    $self->{sth}->jdbc_func("ResultSet.$method");
  };
}

# methods on the JDBC ResultSet object, with an INT argument
foreach my $method (qw/relative absolute/) {
  *{$method} = sub {
    my ($self, $int_arg) = @_;
    $self->{sth}->jdbc_func([$int_arg => SQL_INTEGER], "ResultSet.$method");
  };
}


# methods on the JDBC Statement object, with an INT argument
foreach my $method (qw/setMaxRows setQueryTimeout/) {
  *{$method} = sub {
    my ($self, $int_arg) = @_;
    $self->{sth}->jdbc_func([$int_arg => SQL_INTEGER], "Statement.$method");
  };
}


sub _limit_offset {
  my ($self, $sql_ref, $bind_ref) = @_;

  $self->{offset} = $self->{args}{-offset} || 0;

  # do nothing to the SQL or bind parameters (limit and offset
  # will be handled in prepare() and execute(), see below)
}

sub prepare {
  my ($self, @args) = @_;
  my $limit = $self->{args}{-limit};
  $self->SUPER::prepare(@args);
  $self->setMaxRows($limit + $self->{offset}) if $limit;
  return $self;
}


sub execute {
  my ($self, @args) = @_;
  $self->SUPER::execute(@args);
  $self->absolute($self->{offset}) if $self->{offset};
  return $self;
}


sub rowCount {
  my ($self) = @_;
  $self->{rowCount} = $self->getMemberCount unless exists $self->{rowCount};
  return $self->{rowCount};
}


1;

__END__

=head1 NAME

DBIx::DataModel::Statement::JDBC - Statement for interacting with DBD::JDBC 

=head1 SYNOPSIS

When defining the L<DBIx::DataModel> Schema :

  DBIx::DataModel->Schema("MySchema",
     statementClass => "DBIx::DataModel::Statement::JDBC"
  );

When using the schema:

  my $statement = $source->select(...,
                                  -resultAs => 'statement');

  my $n_rows = $statement->size; # size of result set
  my $row_1 = $statement->next;  # record N° 1;
  $statement->relative(15);      # move down 15 records 
  my $row_16 = $statement->next; # record N° 16
  $statement->beforeFirst;       # back to beginning of result set


=head1 DESCRIPTION

Scrollable statement for L<DBD::JDBC> datasources.
Provides an interface layer to some JDBC methods
on Java C<ResultSet> and C<Statement> objects.


=head1 METHODS

Calls to the following Java methods are encapsulated in the 
statement class. See the JDBC javadoc for details:

=over

=item getMemberCount

number of members in the resultset.

=item size

current number of rows in the resultset 
(may be smaller than C<memberCount> if the
resultset was restricted through C<setMaxRows>).

=item getSQLStatement

=item getRow

index of the current record in the resultset.

=item beforeFirst

=item afterLast

=item isBeforeFirst

=item isAfterLast

=item relative

  $statement->relative($delta)

Move the statement C<$delta> rows from the current position (C<$delta>
may be positive or negative).

=item absolute

  $statement->absolute($row_index)

Move the statement at position C<$row_index>.


=item setMaxRows

  $statement->setMaxRows($max)

Limits the number of rows in ResultSet. Further rows are silently
ignored.

=back

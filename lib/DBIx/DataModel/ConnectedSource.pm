#----------------------------------------------------------------------
package DBIx::DataModel::ConnectedSource;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use Carp;
use Params::Validate qw/validate ARRAYREF HASHREF/;
use Scalar::Util     qw/reftype refaddr/;
use Acme::Damn       qw/damn/;
use Module::Load     qw/load/;
use Scalar::Does     qw/does/;
use Storable         qw/freeze/;

use DBIx::DataModel;
use DBIx::DataModel::Meta::Utils;

use namespace::clean;

{no strict 'refs'; *CARP_NOT = \@DBIx::DataModel::CARP_NOT;}


sub new {
  my ($class, $meta_source, $schema) = @_;

  my $self = bless {meta_source => $meta_source, schema => $schema}, $class;
}


# accessors
DBIx::DataModel::Meta::Utils->define_readonly_accessors(
  __PACKAGE__, qw/meta_source schema/,
);

# additional accessor; here, 'metadm' is a synonym for 'meta_source'
sub metadm { 
  my $self = shift;
  return $self->{meta_source};
}

# methods delegated to the Statement class
foreach my $method (qw/select bless_from_DB/) {
  no strict 'refs';
  *{$method} = sub {
    my $self = shift;

    my $stmt_class = $self->{schema}->metadm->statement_class;
    load $stmt_class;
    my $statement  = $stmt_class->new($self);
    return $statement->$method(@_);
  };
}


# methods delegated to the Source/Table class
foreach my $method (qw/insert update delete/) {
  no strict 'refs';
  *{$method} = sub {
    my $self = shift;

    # create a fake instance of the source classe, containing the schema
    my $obj = bless {__schema => $self->{schema}}, $self->{meta_source}->class;

    # call that instance with all remaining args
    $obj->$method(@_);
  };
}


sub fetch {
  my $self = shift;
  my %select_args;

  # if last argument is a hashref, it contains arguments to the select() call
  no warnings 'uninitialized';
  if ((reftype $_[-1] || '') eq 'HASH') {
    %select_args = %{pop @_};
  }

  return $self->select(-fetch => \@_, %select_args);
}


sub fetch_cached {
  my $self = shift;
  my $dbh_addr    = refaddr $self->schema->dbh;
  my $freeze_args = freeze \@_;
  return $self->{meta_source}{fetch_cached}{$dbh_addr}{$freeze_args}
           ||= $self->fetch(@_);
}



#----------------------------------------------------------------------
# JOIN
#----------------------------------------------------------------------

sub join {
  my ($self, $first_role, @other_roles) = @_;

  # direct references to utility objects
  my $schema      = $self->schema;
  my $metadm      = $self->metadm;
  my $meta_schema = $schema->metadm;

  # find first join information
  my $class  = $metadm->class;
  my $path   = $metadm->path($first_role)
    or croak "could not find role $first_role in $class";

  # build search criteria on %$self from first join information
  my (%criteria, @left_cols);
  my $prefix;
  while (my ($left_col, $right_col) = each %{$path->{on}}) {
    $prefix ||= $schema->placeholder_prefix;
    $criteria{$right_col} = "$prefix$left_col";
    push @left_cols, $left_col;
  }

  # choose source (just a table or build a join) 
  my $source = @other_roles  ? $meta_schema->define_join($path->{to}{name},
                                                         @other_roles)
                             : $path->{to};

  # build args for the statement
  my $connected_source = (ref $self)->new($source, $schema);
  my @stmt_args = ($connected_source, -where => \%criteria);

  # keep a reference to @left_cols so that Source::join can bind them
  push @stmt_args, -_left_cols => \@left_cols;

  # TODO: should add -select_as => 'firstrow' if all multiplicities are 1

  # build and return the new statement
  my $statement = $meta_schema->statement_class->new(@stmt_args);
  return $statement;
}






1;


__END__

=encoding ISO8859-1

=head1 NAME

DBIx::DataModel::ConnectedSource - metasource and schema paired together

=head1 DESCRIPTION

A I<connected source> is a pair of a C<$schema> and C<$meta_source>.
The meta_source holds information about the data structure, and the schema
holds a connection to the database.

=head1 METHODS

Methods are documented in 
L<DBIx::DataModel::Doc::Reference/"CONNECTED SOURCES">


=head2 Constructor

=head3 new

  my $connected_source 
    = DBIx::DataModel::ConnectedSource->new($meta_source, $schema);


=head2 Accessors

=head3 meta_source

=head3 schema

=head3 metadm


=head2 Data retrieval

=head3 select

=head3 fetch

=head3 fetch_cached

=head3 join


=head2 Data manipulation

=head3 insert

=head3 update

=head3 delete


=cut



#----------------------------------------------------------------------
package DBIx::DataModel::ConnectedSource;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
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


# methods delegated to the Source/Table class
foreach my $method (qw/insert update delete select fetch fetch_cached
                       join bless_from_DB/) {
  no strict 'refs';
  *{$method} = sub {
    my $self = shift;

    # create a fake instance of the source classe, containing the schema
    my $obj = bless {__schema => $self->{schema}}, $self->{meta_source}->class;

    # call that instance with all remaining args
    $obj->$method(@_);
  };
}


1;


__END__

=encoding ISO8859-1

=head1 NAME

DBIx::DataModel::ConnectedSource - metasource and schema paired together

=head1 DESCRIPTION

A I<connected source> is a pair of a C<$meta_source> and  and a C<$schema>.
The meta_source holds information about the data structure, and the schema
holds a connection to the database.

Connected sources are used mainly in multi-schema mode, for implementing
calls such as 

  $schema->table($table_name)->select(...);
  $schema->join(qw/Table path1 path2 .../)->select(...);


=head1 METHODS

Methods are documented in 
L<DBIx::DataModel::Doc::Reference/"CONNECTED SOURCES">
Most methods are just delegated calls to C<< $meta_source->class >>,
passing along a reference to C<$schema> through a fake object

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



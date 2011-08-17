package DBIx::DataModel::Compatibility::V0;
use strict;
use warnings;
no strict 'refs';
no warnings 'once';

require DBIx::DataModel::Schema;
require DBIx::DataModel::Statement;

#----------------------------------------------------------------------
package DBIx::DataModel;
#----------------------------------------------------------------------
no warnings 'redefine';
my $orig_Schema = \&Schema;

*Schema = sub {
  my ($class, $schema_class_name, @args) = @_;

  # transform ->Schema('Foo', $dbh) into ->Schema('Foo', dbh => $dbh)
  unshift @args, 'dbh' if @args == 1;
  $class->$orig_Schema(@args);
};

#----------------------------------------------------------------------
package DBIx::DataModel::Schema;
#----------------------------------------------------------------------
*ViewFromRoles = \&join;

#----------------------------------------------------------------------
package DBIx::DataModel::Source;
#----------------------------------------------------------------------

*selectFromRoles = \&join;
*MethodFromRoles 
  = \&DBIx::DataModel::Meta::Source::Table::define_navigation_method;
*table           = \&db_from;

#----------------------------------------------------------------------
package DBIx::DataModel::Statement;
#----------------------------------------------------------------------

use overload

  # overload the coderef operator ->() for backwards compatibility
  # with previous "selectFromRoles" method. 
  '&{}' => sub {
    my $self = shift;
    carp "selectFromRoles is deprecated; use ->join(..)->select(..)";
    return sub {$self->select(@_)};
  };

my $orig_refine = \&refine;
*refine = sub {
  my ($self, %args) = @_;
  $args{-post_bless} = delete $args{-postFetch} if $args{-postFetch};
  $self->$orig_refine(%args);
}






1;


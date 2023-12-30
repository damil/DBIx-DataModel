package DBIx::DataModel::Meta::Schema;
use strict;
use warnings;
use parent 'DBIx::DataModel::Meta';
use DBIx::DataModel;
use DBIx::DataModel::Meta::Utils qw/define_class define_readonly_accessors/;
use DBIx::DataModel::Source::Join;
use DBIx::DataModel::Meta::Source::Join;

use Params::Validate     qw/validate_with SCALAR ARRAYREF CODEREF UNDEF BOOLEAN
                                          OBJECT HASHREF/;
use List::MoreUtils      qw/any firstval lastval uniq/;
use Hash::Util           qw/lock_keys/;
use Module::Load         qw/load/;
use Carp::Clan           qw[^(DBIx::DataModel::|SQL::Abstract)];
use namespace::clean;

#----------------------------------------------------------------------
# Params::Validate specification for new()
#----------------------------------------------------------------------

# new() parameter specification (in Params::Validate format)
my $spec = {
  class                        => {type => SCALAR  },
  isa                          => {type => SCALAR|ARRAYREF,
                                   default => 'DBIx::DataModel::Schema'},

  sql_no_inner_after_left_join => {type => BOOLEAN, optional => 1},
  join_with_USING              => {type => BOOLEAN, optional => 1},

  # fields below are in common with tables (schema is a kind of "pseudo-root")
  auto_insert_columns          => {type => HASHREF, default => {}},
  auto_update_columns          => {type => HASHREF, default => {}},
  no_update_columns            => {type => HASHREF, default => {}},

  # beware: more members of %$spec are added below
};

# parameters for optional subclasses of the builtin source classes
for my $member (qw/table join/) {
  my $capitalized = ucfirst $member;
  my $parent     = "DBIx::DataModel::Source::$capitalized";
  my $meta_class = "DBIx::DataModel::Meta::Source::$capitalized";
  $spec->{$member."_parent"}    = {type    => SCALAR|ARRAYREF,
                                   default => $parent};
  $spec->{$member."_metaclass"} = {type    => SCALAR, 
                                   isa     => $meta_class,
                                   default => $meta_class};
}

# parameters for optional subclasses of the builtin metaclasses
for my $member (qw/association path type/) {
  my $capitalized = ucfirst $member;
  my $meta_class = "DBIx::DataModel::Meta::$capitalized";
  $spec->{$member."_metaclass"} = {type    => SCALAR, 
                                   isa     => $meta_class, 
                                   default => $meta_class};
}

# parameters for optional subclasses of builtin classes
my $statement_class = 'DBIx::DataModel::Statement';
$spec->{statement_class}        = {type    => SCALAR, 
                                   isa     => $statement_class,
                                   default => $statement_class};

my $sqla_abstract_class = 'SQL::Abstract::More';
$spec->{sql_abstract_class}     = {type    => SCALAR, 
                                   isa     => $sqla_abstract_class,
                                   default => $sqla_abstract_class};
$spec->{sql_abstract_args}      = {type    => ARRAYREF, 
                                   default => []};

#----------------------------------------------------------------------
# PUBLIC METHODS : CONSTRUCTOR AND ACCESSORS
#----------------------------------------------------------------------

sub new {
  my $class = shift;

  # check parameters
  my $self = validate_with(
    params      => \@_,
    spec        => $spec,
    allow_extra => 0,
   );

  # canonical representations (arrayref) for some attributes
  for my $attr (qw/isa table_parent parent join_parent/) {
    ref $self->{$attr} or $self->{$attr} = [$self->{$attr}];
  }

  # initial hashrefs for schema members
  $self->{$_} = {} for qw/table association type/;

  # TODO : some checking on auto_update_columns, auto_insert, etc.

  # attributes just for initialisation, don't keep them within $self
  my $isa = delete $self->{isa};

  bless $self, $class;

  # create the Perl class
  define_class(
    name    => $self->{class},
    isa     => $isa,
    metadm  => $self,
   );

  return $self;
}

# accessors for args passed to new()
define_readonly_accessors(__PACKAGE__, grep {$_ ne 'isa'} keys %$spec);

# accessors for internal lists of other meta-objects
foreach my $kind (qw/table association type join/) {
  no strict 'refs';
  # retrieve list of meta-objects
  *{$kind."s"} = sub {
    my $self = shift;
    return values %{$self->{$kind}};
  };

  # retrieve single named object
  *{$kind}     = sub { 
    my ($self, $name) = @_;
    # remove schema prefix, if any
    $name =~ s/^$self->{class}:://;
    return $self->{$kind}{$name};
  };
}


sub db_table {
  my ($self, $db_name) = @_;
  return firstval {uc($_->db_from) eq uc($db_name)} $self->tables;
}


#----------------------------------------------------------------------
# PUBLIC FRONT-END METHODS FOR DECLARING SCHEMA MEMBERS
# (syntactic sugar for back-end define_table(), define_association(), etc.)
#----------------------------------------------------------------------

sub Table {
  my $self = shift;
  my %args;

  # last member of @_ might be a hashref with named parameters
  %args = %{pop @_} if ref $_[-1];

  # parse positional parameters (old syntax)
  my ($class_name, $db_name, @primary_key) = @_;
  $db_name && @primary_key
    or croak "not enough args to \$schema->Table(); "
           . "did you mean \$schema->table() ?";
  $args{class}       ||= $class_name;
  $args{db_name}     ||= $db_name;
  $args{primary_key} ||= \@primary_key;

  # define it
  $self->define_table(%args);

  return $self->class;
}

sub View {
  my $self = shift;
  my %args;

  # last member of @_ might be a hashref with named parameters
  %args = %{pop @_} if ref $_[-1];

  # parse positional parameters (old syntax)
  my ($class_name, $default_columns, $sql, $where, @parents) = @_;
  $args{class}           ||= $class_name;
  $args{db_name}         ||= $sql;
  $args{where}           ||= $where;
  $args{default_columns} ||= $default_columns;
  $args{parents}         ||= [map {$self->table($_)} @parents];

  # define it
  $self->define_table(%args);

  return $self->class;
}

sub Type {
  my ($self, $type_name, %handlers) = @_;

  $self->define_type(
    name     => $type_name,
    handlers => \%handlers,
   );

  return $self->class;
}

sub Association {
  my $self = shift;

  $self->define_association(
    kind => 'Association',
    $self->_parse_association_end(A => shift),
    $self->_parse_association_end(B => shift),
   );

  return $self->class;
}

# MAYBE TODO : sub Aggregation {} with kind => 'Aggregation'.
# This would be good for UML completeness, but rather useless since
# aggregations behave exactly like compositions, so there is nothing
# special to implement.

sub Composition {
  my $self = shift;

  $self->define_association(
    kind => 'Composition',
    $self->_parse_association_end(A => shift),
    $self->_parse_association_end(B => shift),
   );

  return $self->class;
}

#----------------------------------------------------------------------
# PUBLIC BACK-END METHODS FOR DECLARING SCHEMA MEMBERS
#----------------------------------------------------------------------

# common pattern for defining tables, associations and types
foreach my $kind (qw/table association type/) {
  my $metaclass = "${kind}_metaclass";
  no strict 'refs';
  *{"define_$kind"} = sub {
    my $self = shift;

    # force metaclass to be loaded (it could be a user-defined subclass)
    load $self->{$metaclass};

    # instanciate the metaclass
    unshift @_, schema => $self;
    my $meta_obj = $self->{$metaclass}->new(@_);

    # store into our registry (except paths because they are accessed through
    # tables or through associations)
    $self->{$kind}{$meta_obj->{name}} = $meta_obj
      unless $kind eq 'path';

    return $self;
  };
}


# defining joins (different from the common pattern above)
sub define_join {
  my $self = shift;

  # parse arguments
  my ($joins, $aliased_tables, $db_table_by_source) = $self->_parse_join_path(@_);

  # build class name
  my $subclass   = join "", map {($_->{kind}, $_->{name})} @$joins;
  my $class_name = "$self->{class}::AutoJoin::$subclass";

  # do nothing if join class was already loaded
  { no strict 'refs'; return $class_name->metadm if @{$class_name.'::ISA'}; }

  # otherwise, build the new class

  # prepare args for SQL::Abstract::More::join
  my @sqla_join_args = ($joins->[0]{db_table});
  foreach my $join (@$joins[1 .. $#$joins]) {
    my $join_spec = {
      operator  => $join->{kind},
      condition => $join->{condition},
      using     => $join->{using},
    };
    push @sqla_join_args, $join_spec, $join->{db_table};
  }

  # install the Join
  my %args = (
    schema             => $self,
    class              => $class_name,
    parents            => [uniq map {$_->{table}} @$joins],
    sqla_join_args     => \@sqla_join_args,
    aliased_tables     => $aliased_tables,
    db_table_by_source => $db_table_by_source,
  );
  $args{primary_key} = $joins->[0]{primary_key} if $joins->[0]{primary_key};
  my $meta_join = DBIx::DataModel::Meta::Source::Join->new(%args);

  # store into our registry 
  $self->{join}{$subclass} = $meta_join;

  return $meta_join;
}



#----------------------------------------------------------------------
# PRIVATE UTILITY METHODS
#----------------------------------------------------------------------


sub _parse_association_end {
  my ($self, $letter, $end_params)= @_;

  my ($table, $role, $multiplicity, @cols) = @$end_params;

  # prepend schema name in table, unless it already contains "::"
  $table =~ s/^/$self->{class}::/ unless $table =~ /::/;

  # if role is 0, or 'none', or '---', make it empty
  $role = undef if $role && $role =~ /^(0|""|''|-+|none)$/; 

  # pair of parameters for this association end
  my %letter_params = (
    table        => $table->metadm,
    role         => $role,
    multiplicity => $multiplicity,
   );
  $letter_params{join_cols} = \@cols if @cols;
  return $letter => \%letter_params;
}



sub _parse_join_path {
  my ($self, $initial_table, @join_items) = @_;

  # check if there are enough args
  $initial_table && @join_items
    or croak "join: not enough arguments";

  # build first member of the join from the initial table
  my %first_join = (kind => '', name => $initial_table);
  $initial_table =~ s/\|(.+)$//  and $first_join{alias} = $1;
  my $table = $self->table($initial_table)
    or croak "...->join('$initial_table', ...) : this schema has "
           . "no table named '$initial_table'";
  $first_join{table}       = $table;
  $first_join{primary_key} = [$table->primary_key];
  $first_join{db_table}    = $table->db_from;
  $first_join{db_table}   .= "|$first_join{alias}" if $first_join{alias};

  # accumulator structure for the loop below
  my %accu = (
    source         => {($first_join{alias} || $table->name) => \%first_join},
    joins          => [\%first_join],
    join_kind      => undef,
    seen_left_join => undef,
    aliased_tables => {$first_join{alias} ? ($first_join{alias} => $table->name) : ()},
    );
  lock_keys(%accu); # just to make sure that there can be no typos in subs using this %accu


  # loop over remaining join items
  foreach my $join_item (@join_items) {

    # if it is a connector like '=>' or '<=>' or '<=' (see SQLAM syntax) ...
    if ($join_item =~ /^[<>]?=[<>=]?$/) {
      !$accu{join_kind} or croak "'$accu{join_kind}' can't be followed by '$join_item'";
      $accu{join_kind} = $join_item;
      # TODO: accept more general join syntax as recognized by SQLA::More::join
    }

    # otherwise, it must be a path specification
    else {
      $self->_process_next_path_item($join_item, \%accu);
    }
  }

  # index to DB tables from DBIDM source names (will be used by Statement.pm)
  my %db_table_by_source = map {($_ => $accu{source}{$_}{db_table})} keys %{$accu{source}};

  return ($accu{joins}, $accu{aliased_tables}, \%db_table_by_source);
}



my $path_regex = qr/^(?:(.+?)\.)?    # $1: optional source followed by '.'
                     (.+?)           # $2: path name (mandatory)
                     (?:\|(.+))?     # $3: optional alias following a '|'
                    $/x;

sub _process_next_path_item {
  my ($self, $path_item, $accu) = @_;

  # parse
  my ($source_name, $path_name, $alias) = $path_item =~ $path_regex
    or croak "incorrect item '$path_item' in join specification";

  # find source and path information, from join elements seen so far
  my $source_join
    = $source_name ? $accu->{source}{$source_name}
                   : lastval {$_->{table}{path}{$path_name}} @{$accu->{joins}};
  my $path = $source_join && $source_join->{table}{path}{$path_name}
    or croak "couldn't find item '$path_item' in join specification";
  # TODO: also deal with indirect paths (many-to-many)

  # if join kind was not explicit, compute it from min. multiplicity and from previous joins
  if (!$accu->{join_kind}) {
    $accu->{join_kind} = $path->{multiplicity}[0] == 0                                      ?  '=>' 
                       : ($accu->{seen_left_join} && $self->{sql_no_inner_after_left_join}) ?  '=>' 
                       :                                                                      '<=>';
  }
  $accu->{seen_left_join} = 1 if $accu->{join_kind} eq '=>';

  # if max. multiplicity > 1, the join has no primary key
  delete $accu->{joins}[0]{primary_key} if $path->{multiplicity}[1] > 1;

 # build new join hashref and insert it into appropriate structures 
  my %new_join = ( kind      => $accu->{join_kind},
                   name      => $path_item,
                   alias     => $alias,
                   table     => $path->{to},
                   db_table  => $path->{to}->db_from . ($alias ? "|$alias" : ""),
                   condition => {}, # for joining with conditions on left and right columns
                   using     => [], # for joining with a USING clause
                 );
  lock_keys(%new_join);
  $self->_fill_join_condition_and_using(\%new_join, $source_join, $path, $alias);
  push @{$accu->{joins}}, \%new_join;
  $accu->{source}{$alias || $path_name} = \%new_join;

  # remember aliased table
  $accu->{aliased_tables}{$alias} = $path->{to}->name if $alias;

  # reset join kind for next loop
  undef $accu->{join_kind};
}


sub _fill_join_condition_and_using {
  my ($self, $new_join, $source_join, $path, $alias) = @_;

  my $left_table  = $source_join->{alias} || $source_join->{db_table};
  my $right_table = $alias                || $path->{to}->db_from;

  while (my ($left_col, $right_col) = each %{$path->{on}}) {
    if ($left_col eq $right_col) {
      # both cols have equal names, so they can participate in a USING clause
      push @{$new_join->{using}}, $left_col if $new_join->{using};
    }
    else {
      # USING clause is no longer possible as soon as there are unequal names
      undef $new_join->{using};
    }

    # for the ON clause, prefix column names by their table names.
    # Theoretically we should honor SQL::Abstract's "name_sep" setting .. but here there is no access to $statement->sql_abstract
    $new_join->{condition}{"$left_table.$left_col"} = { -ident => "$right_table.$right_col" };
  }
}


1;

__END__

=head1 NAME

DBIx::DataModel::Meta::Schema - Meta-information about a DBIx::DataModel schema

=head1 SYNOPSIS

See synopsis in L<DBIx::DataModel>.

=head1 DESCRIPTION

An instance of this class holds meta-information about a
DBIx::DataModel schema; so it is called a I<meta-schema>. Within the
schema class, the C<metadm> method points to the meta-schema; within the
meta-schema instance, the C<class> method points to the associated class.
Both are created together: the C<new()> method simultaneously builds
a B<subclass> of L<DBIx::DataModel::Schema>, and an B<instance> of
C<DBIx::DataModel::Meta::Schema>.

The meta-schema instance contains information about :

=over

=item *

possible application-specific subclasses of the
builtin C<DBIx::DataModel> classes for statements, associations, types, etc.

=item *

possible overriding of methods at the L<DBI> layer

=item *

global specifications for columns that should be automatically
inserted or updated in every table.

=item *

lists of tables, types, associations declared within that schema.

=back

and it contains methods for declaring those meta-objects.


=head1 CONSTRUCTOR

=head2 new

  my $meta_schema = DBIx::DataModel::Meta::Schema->new(%args);

Simultaneously creates a new subclass of L<DBIx::DataModel::Schema>, and 
an new instance of DBIx::DataModel::Meta::Schema. Arguments are
described in the  
L<reference documentation|DBIx::DataModel::Doc::Reference/"Schema() / define_schema()">.


=head1 FRONT-END METHODS FOR DECLARING SCHEMA MEMBERS


=head2 Table

  $meta_schema->Table($class_name, $db_name, @primary_key, \%options);


=head2 View

  $meta_schema->View($class_name, $columns, $db_tables, 
                     \%where, @parent_tables);


=head2 Association

  $schema->Association([$class1, $role1, $multiplicity1, @columns1],
                       [$class2, $role2, $multiplicity2, @columns2]);


=head2 Composition

  $schema->Composition([$class1, $role1, $multiplicity1, @columns1], 
                       [$class2, $role2, $multiplicity2, @columns2]);


=head3 Type

  $meta_schema->Type($type_name => 
     $handler_name_1 => sub { ... },
     ...
   );




=head1 PRIVATE METHODS

=head2 _parse_association_end

Utility methods for parsing both ends of an association declaration.

=head2 _parse_join_path

Utility method for parsing arguments to L</join>, finding the most
appropriate source for each path item, retrieving
implicit left or inner connectors, and keeping track of aliases.




=cut






















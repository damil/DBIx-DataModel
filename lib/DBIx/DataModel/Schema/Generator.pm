#----------------------------------------------------------------------
package DBIx::DataModel::Schema::Generator;
#----------------------------------------------------------------------

# see POD doc at end of file
# version : see DBIx::DataModel

use strict;
use warnings;
no warnings 'uninitialized';
use Carp;
use List::Util   qw/max/;
use Exporter     qw/import/;
use DBI;
use Try::Tiny;
use Module::Load qw/load/;

{no strict 'refs'; *CARP_NOT = \@DBIx::DataModel::CARP_NOT;}

our @EXPORT = qw/fromDBIxClass fromDBI/;


sub new {
  my ($class, @args) = @_;
  my $self =  bless {@args}, $class;
  $self->{-schema} ||= "My::Schema";
  return $self;
}


sub fromDBI {
  # may be called as ordinary sub or as method
  my $self = ref $_[0] eq __PACKAGE__ ? shift : __PACKAGE__->new(@ARGV);

  my $arg1    = shift or croak "missing arg (dsn for DBI->connect(..))";
  my $dbh = (ref $arg1 && $arg1->isa('DBI::db')) ? $arg1 : do {
    my $user    = shift || "";
    my $passwd  = shift || "";
    my $options = shift || {RaiseError => 1};
    DBI->connect($arg1, $user, $passwd, $options)
      or croak "DBI->connect failed ($DBI::errstr)";
  };

  my %args 
    = (catalog => undef, schema => undef, table => undef, type => "TABLE");
  my $tables_sth = $dbh->table_info(@args{qw/catalog schema table type/});
  my $tables     = $tables_sth->fetchall_arrayref({});

 TABLE:
  foreach my $table (@$tables) {

    # get primary key info
    my @table_id = @{$table}{qw/TABLE_CAT TABLE_SCHEM TABLE_NAME/};
    my $pkey = join(" ", $dbh->primary_key(@table_id)) || "unknown_pk";

    my $table_info  = {
      classname => _table2class($table->{TABLE_NAME}),
      tablename => $table->{TABLE_NAME},
      pkey      => $pkey,
      remarks   => $table->{REMARKS},
    };

    # insert into list of tables
    push @{$self->{tables}}, $table_info;


    # get association info (in an eval because unimplemented by some drivers)
    my $fkey_sth = try {$dbh->foreign_key_info(@table_id,
                                                undef, undef, undef)}
      or next TABLE;

    while (my $fk_row = $fkey_sth->fetchrow_hashref) {

      # hack for unifying "ODBC" or "SQL/CLI" column names (see L<DBI>)
      $fk_row->{"UK_$_"} ||= $fk_row->{"PK$_"} for qw/TABLE_NAME COLUMN_NAME/;
      $fk_row->{"FK_$_"} ||= $fk_row->{"FK$_"} for qw/TABLE_NAME COLUMN_NAME/;

      my @assoc = (
        { table    => _table2class($fk_row->{UK_TABLE_NAME}),
          col      => $fk_row->{UK_COLUMN_NAME},
          role     => _table2role($fk_row->{UK_TABLE_NAME}),
          mult_min => 1, #0/1 (TODO: depend on is_nullable on other side)
          mult_max => 1,
        },
        { table    => _table2class($fk_row->{FK_TABLE_NAME}),
          col      => $fk_row->{FK_COLUMN_NAME},
          role     => _table2role($fk_row->{FK_TABLE_NAME}, "s"),
          mult_min => 0,
          mult_max => '*',
        }
       );
      push @{$self->{assoc}}, \@assoc;
    }
  }

  $self->generate;
}


sub fromDBIxClass {

  # may be called as ordinary sub or as method
  my $self = ref $_[0] eq __PACKAGE__ ? shift : __PACKAGE__->new(@ARGV);

  my $dbic_schema = shift or croak "missing arg (DBIC schema name)";

  # load the DBIx::Class schema
  load $dbic_schema or croak $@;

  # global hash to hold assoc. info (because we must collect info from
  # both tables to get both directions of the association)
  my %associations;

  # foreach  DBIC table class ("moniker" : short class name)
  foreach my $moniker ($dbic_schema->sources) {
    my $source = $dbic_schema->source($moniker); # full DBIC class

    # table info
    my $table_info  = {
      classname => $moniker,
      tablename => $source->from,
      pkey      => join(" ", $source->primary_columns),
    };

    # inflated columns
    foreach my $col ($source->columns) {
      my $column_info  = $source->column_info($col);
      my $inflate_info = $column_info->{_inflate_info} 
        or next;

      # don't care about inflators for related objects
      next if $source->relationship_info($col);

      my $data_type = $column_info->{data_type};
      push @{$self->{column_types}{$data_type}{$moniker}}, $col;
    }

    # insert into list of tables
    push @{$self->{tables}}, $table_info;

    # association info 
    foreach my $relname ($source->relationships) {
      my $relinfo   = $source->relationship_info($relname);

      # extract join keys from $relinfo->{cond} (which 
      # is of shape {"foreign.k1" => "self.k2"})
      my ($fk, $pk) = map /\.(.*)/, %{$relinfo->{cond}};

      # moniker of the other side of the relationship
      my $relmoniker = $source->related_source($relname)->source_name;

      # info structure
      my %info = (
        table    => $relmoniker,
        col      => $fk,
        role     => $relname,

        # compute multiplicities
        mult_min => $relinfo->{attrs}{join_type} eq 'LEFT' ? 0   : 1,
        mult_max => $relinfo->{attrs}{accessor} eq 'multi' ? "*" : 1,
      );

      # store assoc info into global hash; since both sides of the assoc must 
      # ultimately be joined, we compute a unique key from alphabetic ordering
      my ($key, $index) = ($moniker cmp $relmoniker || $fk cmp $pk) < 0
                        ? ("$moniker/$relmoniker/$fk/$pk", 0)
                        : ("$relmoniker/$moniker/$pk/$fk", 1);
      $associations{$key}[$index] = \%info;

      # info on other side of the association
      my $other_index = 1 - $index;
      my $other_assoc = $associations{$key}[1 - $index] ||= {};
      $other_assoc->{table} ||= $moniker;
      $other_assoc->{col}   ||= $pk;
      defined $other_assoc->{mult_min} or $other_assoc->{mult_min} = 1;
      defined $other_assoc->{mult_max} or $other_assoc->{mult_max} = 1;
    }
  }

  $self->{assoc} = [values %associations];

  $self->generate;
}

# other name for this method
*fromDBIC = \&fromDBIxClass;


sub generate {
  my ($self) = @_;

  # compute max length of various fields (for prettier source alignment)
  my %l;
  foreach my $field (qw/classname tablename pkey/) {
    $l{$field} = max map {length $_->{$field}} @{$self->{tables}};
  }
  foreach my $field (qw/col role mult/) {
    $l{$field} = max map {length $_->{$field}} map {(@$_)} @{$self->{assoc}};
  }
  $l{mult} = max ($l{mult}, 4);

  # start emitting code
  print <<__END_OF_CODE__;
use strict;
use warnings;
use DBIx::DataModel;

DBIx::DataModel  # no semicolon (intentional)

#---------------------------------------------------------------------#
#                         SCHEMA DECLARATION                          #
#---------------------------------------------------------------------#
->Schema('$self->{-schema}')

#---------------------------------------------------------------------#
#                         TABLE DECLARATIONS                          #
#---------------------------------------------------------------------#
__END_OF_CODE__

  my $colsizes = "%-$l{classname}s %-$l{tablename}s %-$l{pkey}s";
  my $format   = "->Table(qw/$colsizes/)\n";

  printf         "#          $colsizes\n", qw/Class Table PK/;
  printf         "#          $colsizes\n", qw/===== ===== ==/;

  foreach my $table (@{$self->{tables}}) {
    if ($table->{remarks}) {
      $table->{remarks} =~ s/^/# /gm;
      print "\n$table->{remarks}\n";
    }
    printf $format, $table->{classname}, $table->{tablename}, $table->{pkey};
  }


  $colsizes = "%-$l{classname}s %-$l{role}s  %-$l{mult}s %-$l{col}s";
  $format   = "  [qw/$colsizes/]";

  print <<__END_OF_CODE__;

#---------------------------------------------------------------------#
#                      ASSOCIATION DECLARATIONS                       #
#---------------------------------------------------------------------#
__END_OF_CODE__

  printf         "#     $colsizes\n", qw/Class Role Mult Join/;
  printf         "#     $colsizes",   qw/===== ==== ==== ====/;


  foreach my $a (@{$self->{assoc}}) {

    # for prettier output, make sure that multiplicity "1" is first
    @$a = reverse @$a if $a->[1]{mult_max} eq "1"
                      && $a->[0]{mult_max} eq "*";

    # complete association info
    for my $i (0, 1) {
      $a->[$i]{role} ||= "---";
      my $mult       = "$a->[$i]{mult_min}..$a->[$i]{mult_max}";
      $a->[$i]{mult} = {"0..*" => "*", "1..1" => "1"}->{$mult} || $mult;
    }

    print "\n->Association(\n";
    printf $format, @{$a->[0]}{qw/table role mult col/};
    print ",\n";
    printf $format, @{$a->[1]}{qw/table role mult col/};
    print ")\n";
  }
  print "\n;\n";

  # column types
  print <<__END_OF_CODE__;

#---------------------------------------------------------------------#
#                             COLUMN TYPES                            #
#---------------------------------------------------------------------#
# $self->{-schema}->ColumnType(ColType_Example =>
#   fromDB => sub {...},
#   toDB   => sub {...});

# $self->{-schema}::SomeTable->ColumnType(ColType_Example =>
#   qw/column1 column2 .../);

__END_OF_CODE__

  while (my ($type, $targets) = each %{$self->{column_types} || {}}) {
    print <<__END_OF_CODE__;
# $type
$self->{-schema}->ColumnType($type =>
  fromDB => sub {},   # SKELETON .. PLEASE FILL IN
  toDB   => sub {});
__END_OF_CODE__

    while (my ($table, $cols) = each %$targets) {
      printf "%s::%s->ColumnType($type => qw/%s/);\n",
        $self->{-schema}, $table, join(" ", @$cols);
    }
    print "\n";
  }

  # end of module
  print "\n\n1;\n";
}


# support for SQL::Translator::Producer

sub produce {
  my $tr = shift;

  my $self = __PACKAGE__->new(%{$tr->{producer_args} || {}});

  my $schema = $tr->schema;
  foreach my $table ($schema->get_tables) {
    my $tablename = $table->name;
    my $classname = _table2class($tablename);
    my $pk        = $table->primary_key;
    my @pkey      = $pk ? ($pk->field_names) : qw/unknown_pk/;

    my $table_info  = {
      classname => $classname,
      tablename => $tablename,
      pkey      => join(" ", @pkey),
      remarks   => join("\n", $table->comments),
    };
    push @{$self->{tables}}, $table_info;

    my @foreign_keys 
      = grep {$_->type eq 'FOREIGN KEY'} ($table->get_constraints);

    my $role      = _table2role($tablename, "s");
    foreach my $fk (@foreign_keys) {
      my $ref_table  = $fk->reference_table;
      my @ref_fields = $fk->reference_fields;

      my @assoc = (
        { table    => _table2class($ref_table),
          col      => $table_info->{pkey},
          role     => _table2role($ref_table),
          mult_min => 1, #0/1 (TODO: depend on is_nullable on other side)
          mult_max => 1,
        },
        { table    => $classname,
          col      => join(" ", $fk->fields),
          role     => $role,
          mult_min => 0,
          mult_max => '*',
        }
       );
      push @{$self->{assoc}}, \@assoc;
    }
  }

  local *STDOUT;
  my $out = "";
  open STDOUT, ">",  \$out;
  $self->generate;
  return $out;
}



#----------------------------------------------------------------------
# UTILITY METHODS/FUNCTIONS
#----------------------------------------------------------------------

# generate a Perl classname from a database table name
sub _table2class{
  my ($tablename) = @_;

  my $classname = join '', map ucfirst, split /[\W_]+/, lc $tablename;
}

# singular / plural inflection. Start with simple-minded defaults,
# and try to more sophisticated use Lingua::Inflect if module is installed
my $to_S  = sub {(my $r = $_[0]) =~ s/s$//i; $r};
my $to_PL = sub {$_[0] . "s"};
eval "use Lingua::EN::Inflect::Phrase qw/to_S to_PL/;"
   . "\$to_S = \\&to_S; \$to_PL = \\&to_PL;"
  or warn "Lingua::EN::Inflect::Phrase is recommended; please install it to "
        . "generate better names for associations";
;

# generate a rolename from a database table name
sub _table2role{
  my ($tablename, $plural) = @_;

  my $inflect         = $plural ? $to_PL : $to_S;
  # my ($first, @other) = map {$inflect->($_)} split /[\W_]+/, lc $tablename;
  # my $role            = join '_', $first, @other;
  my $role            = $inflect->(lc $tablename);
  return $role;
}





1; 

__END__

=head1 NAME

DBIx::DataModel::Schema::Generator - automatically generate a schema for DBIx::DataModel

=head1 SYNOPSIS

  perl -MDBIx::DataModel::Schema::Generator      \
       -e "fromDBI('dbi:connection:string')" --  \
       -schema My::New::Schema > My/New/Schema.pm

  perl -MDBIx::DataModel::Schema::Generator      \
       -e "fromDBIxClass('Some::DBIC::Schema')" -- \
       -schema My::New::Schema > My/New/Schema.pm

If L<SQL::Translator|SQL::Translator> is installed

  sqlt -f <parser> -t DBIx::DataModel::Schema::Generator <parser_input>



=head1 DESCRIPTION

Generates schema, table and association declarations
for L<DBIx::DataModel|DBIx::DataModel>, either from
a L<DBI|DBI> connection, or from an existing 
L<DBIx::Class|DBIx::Class> schema. The result is written
on standard output and can be redirected to a F<.pm> file.

The module can be called easily from the perl command line,
as demonstrated in the synopsis above. Command-line arguments
after C<--> are passed to method L<new>.

Alternatively, if L<SQL::Translator|SQL::Translator> is 
installed, you can use C<DBIx::DataModel::Schema::Generator>
as a producer, translating from any available
C<SQL::Translator> parser.

The generated code is a skeleton that most probably will need
some manual additions or modifications to get a fully functional 
datamodel, because part of the information cannot be inferred 
automatically. In particular, you should inspect the names 
and multiplicities of the generated associations, and decide
which of these associations should rather be 
L<compositions|DBIx::DataModel::Doc::Reference/Composition>;
and you should declare the 
L<column types|DBIx::DataModel::Doc::Reference/ColumnType>
for columns that need automatic inflation/deflation.


=head1 METHODS

=head2 new

  my $generator = DBIx::DataModel::Schema::Generator->new(@args);

Creates a new instance of a schema generator.
Functions L<fromDBI> and L<fromDBIxClass> automatically call
C<new> if necessary, so usually you do not need to call it yourself.
Arguments are :

=over

=item -schema

Name of the L<DBIx::DataModel::Schema|DBIx::DataModel::Schema>
subclass that will be generated (default is C<My::Schema>).

=back


=head2 fromDBI

  $generator->fromDBI(@dbi_connection_args);
  # or
  fromDBI(@dbi_connection_args);

Connects to a L<DBI|DBI> data source, gathers information from the
database about tables, primary and foreign keys, and generates
a C<DBIx::DataModel> schema on standard output.

This can be used either as a regular method, or as 
a function (this function is exported by default).
In the latter case, a generator is automatically 
created by calling L<new> with arguments C<@ARGV>.

The DBI connection arguments are as in  L<DBI/connect>.
Alternatively, an already connected C<$dbh> can also be
passed as argument to C<fromDBI()>.


=head2 fromDBIxClass

  $generator->fromDBIxClass('Some::DBIC::Schema');
  # or
  fromDBIxClass('Some::DBIC::Schema');

Loads an existing  L<DBIx::Class|DBIx::Class> schema, and translates
its declarations into a C<DBIx::DataModel> schema 
printed on standard output.

This can be used either as a regular method, or as 
a function (this function is exported by default).
In the latter case, a generator is automatically 
created by calling L<new> with arguments C<@ARGV>.

=head2 produce

Implementation of L<SQL::Translator::Producer|SQL::Translator::Producer>.


=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>

=head1 COPYRIGHT & LICENSE

Copyright 2008, 2012 Laurent Dami.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.





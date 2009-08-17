#----------------------------------------------------------------------
package DBIx::DataModel;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use DBIx::DataModel::Schema;

our $VERSION = '1.19';

sub Schema {
  my $class = shift;

  return DBIx::DataModel::Schema->_subclass(@_);
}


1; # End of DBIx::DataModel

__END__

=head1 NAME

DBIx::DataModel - UML-based Object-Relational Mapping (ORM) framework

=head1 SYNOPSIS

=head2 in file "MySchema.pm"

=head3 Schema 

Declare the schema, which automatically creates a Perl package.

  # do NOT declare here "package MySchema;"
  use DBIx::DataModel;
  DBIx::DataModel->Schema('MySchema'); # 'MySchema' is now a Perl package

=head3 Tables

Declare the tables with 
C<< (Perl name, DB name, primary key column(s)) >>.
Each table then becomes a Perl package (prefixed with the Schema name).

  MySchema->Table(qw/Employee   Employee   emp_id/)
          ->Table(qw/Department Department dpt_id/)
          ->Table(qw/Activity   Activity   act_id/);

=head3 Associations

Declare associations or compositions in UML style
( C<< [table1 role1 multiplicity1 join1], [table2...] >>).

  MySchema->Composition([qw/Employee   employee   1 /],
                        [qw/Activity   activities * /])
          ->Association([qw/Department department 1 /],
                        [qw/Activity   activities * /]);

Declare a n-to-n association, on top of the linking table

  MySchema->Association([qw/Department departments * activities department/]);
                        [qw/Employee   employees   * activities employee/]);

=head3 Columns

Declare "column types" with some handlers ..

  # date conversion between database (yyyy-mm-dd) and user (dd.mm.yyyy)
  MySchema->ColumnType(Date => 
     fromDB   => sub {$_[0] =~ s/(\d\d\d\d)-(\d\d)-(\d\d)/$3.$2.$1/},
     toDB     => sub {$_[0] =~ s/(\d\d)\.(\d\d)\.(\d\d\d\d)/$3-$2-$1/},
     validate => sub {$_[0] =~ m/(\d\d)\.(\d\d)\.(\d\d\d\d)/});
  
  # 'percent' conversion between database (0.8) and user (80)
  MySchema->ColumnType(Percent => 
     fromDB   => sub {$_[0] *= 100 if $_[0]},
     toDB     => sub {$_[0] /= 100 if $_[0]},
     validate => sub {$_[0] =~ /1?\d?\d/});
  
  MySchema->ColumnType(Multivalue =>
     fromDB   => sub {$_[0] = [split /;/, $_[0] || ""]     },
     toDB     => sub {$_[0] = join ";", @$_[0] if ref $_[0]});

.. and apply these "column types" to some of our columns

  MySchema::Employee->ColumnType(Date    => qw/d_birth/);
  MySchema::Activity->ColumnType(Date    => qw/d_begin d_end/)
                    ->ColumnType(Percent => qw/activity_rate/);

Declare a column that will be filled automatically
at each update

  MySchema->AutoUpdateColumns(last_modif => 
    sub{$ENV{REMOTE_USER}.", ".scalar(localtime)});

Declare a column that will be not be sent when
updating records (for example if that column is 
filled automatically by the database) 

  MySchema->NoUpdateColumns(qw/date_modif time_modif/);


=head3 Additional methods

For details that could not be expressed in a declarative way,
just add a new method into the table class (but in that case,
Schema and Table declarations should be in a BEGIN block, so that
the table class is defined before you start adding methods to it).

  package MySchema::Activity; 
  
  sub activePeriod {
    my $self = shift;
    $self->{d_end} ? "from $self->{d_begin} to $self->{d_end}"
                   : "since $self->{d_begin}";
  }

=head3 Data tree expansion

Declare how to automatically expand objects into data trees

  MySchema::Activity->AutoExpand(qw/employee department/);

=head3 Automatic schema generation

  perl -MDBIx::DataModel::Schema::Generator      \
       -e "fromDBI('dbi:connection:string')" --  \
       -schema My::New::Schema > My/New/Schema.pm

See L<DBIx::DataModel::Schema::Generator>.



=head2 in file "myClient.pl"

=head3 Database connection

  use MySchema;
  use DBI;
  my $dbh = DBI->connect($dsn, ...);
  MySchema->dbh($dbh);

=head3 Simple data retrieval

Search employees whose name starts with 'D'
(select API is taken from L<SQL::Abstract>)

  my $empl_D = MySchema::Employee->select(
    -where => {lastname => {-like => 'D%'}}
  );

idem, but we just want a subset of the columns, and order by age.

  my $empl_F = MySchema::Employee->select(
    -columns => [qw/firstname lastname d_birth/],
    -where   => {lastname => {-like => 'F%'}},
    -orderBy => 'd_birth'
  );

Print some info from employees. Because of the
'fromDB' handler associated with column type 'date', column 'd_birth'
has been automatically converted to display format.

  foreach my $emp (@$empl_D) {
    print "$emp->{firstname} $emp->{lastname}, born $emp->{d_birth}\n";
  }

Same thing, but using method calls instead of direct access to the
hashref (must enable AUTOLOAD in the table or the whole schema)

  MySchema::Employee->Autoload(1); # or MySchema->Autoload(1)
  foreach my $emp (@$empl_D) {
    printf "%s %s, born %s\n", $emp->firstname, $emp->lastname, $emp->d_birth;
  }

=head3 Methods to follow joins

Follow the joins through role methods

  foreach my $act (@{$emp->activities}) {
    printf "working for %s from $act->{d_begin} to $act->{d_end}", 
      $act->department->name;
  }

Role methods can take arguments too, like C<select()>

  my $recentAct  
    = $dpt->activities(-where => {d_begin => {'>=' => '2005-01-01'}});
  my @recentEmpl 
    = map {$_->employee(-columns => [qw/firstname lastname/])} @$recentAct;

=head3 Data export : just regular hashrefs

Export the data : get related records and insert them into
a data tree in memory; then remove all class information and 
export that tree.

  $_->expand('activities') foreach @$empl_D;
  my $export = MySchema->unbless({employees => $empl_D});
  use Data::Dumper; print Dumper ($export); # export as PerlDump
  use XML::Simple;  print XMLout ($export); # export as XML
  use JSON;         print to_json($export); # export as Javascript
  use YAML;         print Dump   ($export); # export as YAML

B<Note>: the C<unbless> step is optional; it is proposed here
because some exporter modules will not work if they
encounter a blessed reference.


=head3 Database join

Select associated tables directly from a database join, 
in one single SQL statement (instead of iterating through role methods).

  my $lst = MySchema->join(qw/Employee activities department/)
                    ->select(-columns => [qw/lastname dept_name d_begin/],
                             -where   => {d_begin => {'>=' => '2000-01-01'}});

Same thing, but forcing INNER joins

  my $lst = MySchema->join(qw/Employee <=> activities <=> department/)
                    ->select(...);


=head3 Statements and pagination

Instead of retrieving directly a list or records, get a
L<statement|DBIx::DataModel::Statement> :

  my $statement 
    = MySchema->join(qw/Employee activities department/)
              ->select(-columns  => [qw/lastname dept_name d_begin/],
                       -where    => {d_begin => {'>=' => '2000-01-01'}},
                       -resultAs => 'statement');

Retrieve a single row from the statement

  my $single_row = $statement->next or die "no more records";

Retrieve several rows at once

  my $rows = $statement->next(10); # arrayref

Go to a specific page and retrieve the corresponding rows

  my $statement 
    = MySchema->join(qw/Employee activities department/)
              ->select(-columns  => [qw/lastname dept_name d_begin/],
                       -resultAs => 'statement',
                       -pageSize => 10);
  
  $statement->gotoPage(3);    # absolute page positioning
  $statement->shiftPages(-2); # relative page positioning
  my ($first, $last) = $statement->pageBoundaries;
  print "displaying rows $first to $last:";
  some_print_row_method($_) foreach @{$statement->pageRows};


=head3 Efficient use of statements 

For fetching related rows : prepare a statement before the loop, execute it
at each iteration.


  my $statement = My::Table->join(qw/role1 role2/)
                           ->prepare(-columns => ...,
                                     -where   => ...);
  my $list = My::Table->select(...);
  foreach my $obj (@$list) {
    my $related_rows = $statement->execute($obj)->all;
    ... 
  }

Fast statement : each data row is retrieved into the same
memory location (avoids the overhead of allocating a hashref
for each row). Faster, but such rows cannot be accumulated
into an array (they must be used immediately) :

  my $fast_stmt = ..->select(..., -resultAs => "fast_statement");
  while (my $row = $fast_stmt->next) {
    do_something_immediately_with($row);
  }



=head1 DESCRIPTION

=head2 Introduction

C<DBIx::DataModel> is a framework for building Perl
abstractions (classes, objects and methods) that interact
with relational database management systems (RDBMS).  
Of course the ubiquitous L<DBI|DBI> module is used as
a basic layer for communicating with databases; on top of that,
C<DBIx::DataModel> provides facilities for generating SQL queries,
joining tables automatically, navigating through the results,
converting values, and building complex datastructures so that other
modules can conveniently exploit the data.

=head2 Perl ORMs

There are many other CPAN modules offering 
somewhat similar features, like
L<Class::DBI|Class::DBI>,
L<DBIx::Class|DBIx::Class>,
L<Tangram|Tangram>,
L<Rose::DB::Object|Rose::DB::Object>,
L<Jifty::DBI|Jifty::DBI>,
L<Fey::ORM|Fey::ORM>,
just to name a few well-known alternatives.
Frameworks in this family are called
I<object-relational mappings> (ORMs)
-- see L<http://en.wikipedia.org/wiki/Object-relational_mapping>.
The mere fact that Perl ORMs are so numerous demonstrates that there is
more than one way to do it!

For various reasons, none of these did fit nicely in my context, 
so I decided to write C<DBIx:DataModel>. 
Of course there might be also some reasons why C<DBIx:DataModel>
will not fit in I<your> context, so just do your own shopping.
Comparing various ORMs is complex and time-consuming, because
of the many issues and design dimensions involved; as far as I know,
there is no thorough comparison summary, but here are some pointers :

=over

=item * 

general discussion on RDBMS - Perl 
mappings at L<http://poop.sourceforge.net> (good but outdated).

=item *

L<http://www.perlfoundation.org/perl5/index.cgi?orm>

=item *

L<http://osdir.com/ml/lang.perl.modules.dbi.rose-db-object/2006-06/msg00021.html>, a detailed comparison between Rose::DB and DBIx::Class.

=back

=head2 Strengths of C<DBIx::DataModel>

The L<DESIGN|DBIx::DataModel::Doc::Design> chapter of this 
documentation will help you understand the philosophy of
C<DBIx::DataModel>. Just as a summary, here are some
of its strong points :

=over

=item *

UML-style declaration of relationships (instead of 'has_many', 
'belongs_to', etc.)

=item *

efficiency through fine control of collaboration with the DBI layer
(prepare/execute, fetch into reusable memory location, etc.)

=item *

improved API for SQL::Abstract (named parameters, simplified 'orderBy')

=item *

clear conceptual distinction between 

=over

=item *

data sources         (tables and views),

=item *

database statements  (stateful objects representing stepwise building
                      of an SQL query and stepwise retrieval of results),

=item *

data rows            (lightweight hashrefs containing nothing but column
                      names and values)

=back 

=item *

joins with simple syntax and possible override of default 
INNER JOIN/LEFT JOIN properties; instances of joins multiply
inherit from their member tables.

=item *

named placeholders

=item *

nested, cross-database transactions

=back

C<DBIx::DataModel> is used in production
within a mission-critical application with several hundred
users, for managing Geneva courts of law.


=head2 Limitations

Here are some current limitations of C<DBIx::DataModel> :

=over

=item no schema versioning

C<DBIx::DataModel> knows very little about the database
schema (only tables, primary and foreign keys); therefore
it provides no support for schema changes (and seldom
needs to know about them).

=item no object caching nor 'dirty columns'

C<DBIx::DataModel> does not keep track of data mutations
in memory, and therefore provides no support for automatically
propagating changes into the database; the client code has
explicitly manage C<insert> and C<update> operations.


=item no 'cascaded update' nor 'insert or create'

Cascaded inserts and deletes are supported, but not cascaded updates.
This would need 'insert or create', which at the moment is not
supported either.

=back


=head1 INDEX TO THE DOCUMENTATION

Although the basic principles are quite simple, there are many
details to discuss, so the documentation is quite long.
In an attempt to accomodate for different needs of readers,
it has been structured as follows :

=over

=item * 

The L<DESIGN|DBIx::DataModel::Doc::Design> chapter covers the
architecture of C<DBIx::DataModel>, its main distinctive features and
the motivation for such features; it is of interest if you are
comparing various ORMs, or if you want to globally understand
how C<DBIx::DataModel> works, and what it can or cannot do.
This chapter also details the concept of B<statements>, which
underlies all SELECT requests to the database.

=item * 

The L<QUICKSTART|DBIx::DataModel::Doc::Quickstart> chapter
is a guided tour that 
summarizes the main steps to get started with the framework.

=item *

The L<REFERENCE|DBIx::DataModel::Doc::Reference> chapter
is a complete reference to all methods, structured along usage steps:
creating a schema, populating it with table and associations,
parameterizing the framework, and finally data retrieval and
manipulation methods.

=item *

The L<MISC|DBIx::DataModel::Doc::Misc> chapter discusses
how this framework interacts with its context
(Perl namespaces, DBI layer, etc.), and
how to work with self-referential associations.

=item *

The L<INTERNALS|DBIx::DataModel::Doc::Internals> chapter
documents the internal structure of the framework, for programmers
who might be interested in extending it.


=item *

The L<GLOSSARY|DBIx::DataModel::Doc::Glossary> 
defines terms used in this documentation,
and points to the software constructs that
implement these terms.

=item *

The L<DELTA_1.0|DBIx::DataModel::Doc::Delta_1.0> chapter
summarizes the differences with previous version 0.35.


=item *

The L<DBIx::DataModel::Schema::Generator|DBIx::DataModel::Schema::Generator>
documentation explains how to automatically generate a schema from
a C<DBI> connection, from a L<SQL::Translator|SQL::Translator> description
or from an existing C<DBIx::Class|DBIx::Class> schema.

=item *

The L<DBIx::DataModel::Statement|DBIx::DataModel::Statement>
documentation documents the methods of 
statements (not included in the 
general L<REFERENCE|DBIx::DataModel::Doc::Reference> chapter).

=back

=head1 SIDE-EFFECTS

Upon loading, L<DBIx::DataModel::View> adds a coderef
into global C<@INC> (see L<perlfunc/require>), so that it can take 
control and generate a class on the fly when retrieving frozen
objects from L<Storable/thaw>. This should be totally harmless unless
you do some very special things with C<@INC>.


=head1 SUPPORT AND CONTACT

Bugs should be reported via the CPAN bug tracker at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=DBIx-DataModel>.

There is a discussion group at 
L<http://groups.google.com/group/dbix-datamodel>.

Sources are stored in an open repository at 
L<http://svn.ali.as/cpan/trunk/DBIx-DataModel>.

=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>

=head1 ACKNOWLEDGEMENTS

Thanks to Cedric Bouvier for some bug fixes and improvements, and to
Terrence Brannon for many fixes in the documentation.

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2009 by Laurent Dami.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

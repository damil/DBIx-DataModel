#----------------------------------------------------------------------
package DBIx::DataModel::Schema;
#----------------------------------------------------------------------

# see POD doc at end of file
# version : see DBIx::DataModel

use warnings;
use strict;
use Carp;
use base 'DBIx::DataModel::Base';
use SQL::Abstract 1.61;
use DBIx::DataModel::Table;
use DBIx::DataModel::View;
use POSIX        (); # INT_MAX
use Scalar::Util qw/blessed reftype/;

our @CARP_NOT = qw/DBIx::DataModel         DBIx::DataModel::Source
		   DBIx::DataModel::Table  DBIx::DataModel::View         /;

#----------------------------------------------------------------------
# PACKAGE DATA
#----------------------------------------------------------------------

my $sqlDialects = {
 Default => {
   innerJoin         => "%s INNER JOIN %s ON %s",
   leftJoin          => "%s LEFT OUTER JOIN %s ON %s",
   joinAssociativity => "left",
   columnAlias       => "%s AS %s",
   tableAlias        => "%s AS %s",
   limitOffset       => "LimitOffset",
 },
 MsAccess => {
   innerJoin         => "%s INNER JOIN (%s) ON %s",
   leftJoin          => "%s LEFT OUTER JOIN (%s) ON %s",
   joinAssociativity => "right",
   limitOffset       => undef,
 },
 BasisODBC => {
   innerJoin         => undef,
 },
 BasisJDBC => {
   columnAlias       => "%s %s",
 },
 MySQL => {
   limitOffset       => "LimitXY",
 },
};

my $sqlLimitDialects = {
  LimitOffset => sub {"LIMIT ? OFFSET ?",         @_},
  LimitXY     => sub {"LIMIT ?, ?",       reverse @_},
  LimitYX     => sub {"LIMIT ?, ?",               @_},
};

#----------------------------------------------------------------------
# COMPILE-TIME METHODS
#----------------------------------------------------------------------


sub _subclass { # this is the implementation of DBIx::DataModel->Schema(..)
  my ($class, $pckName, @args) = @_;

  my %params = (@args == 1)      # if only one arg ..
             ? (dbh => $args[0]) # .. then old API (positional arg : dbh)
             : @args;            # .. otherwise, named args

  # backwards compatibility 
  my $tmp;
  $tmp = delete $params{cursorClass} 
    and $params{statementClass} = $tmp;

  # check validity of parameters
  my $regex = qr/^(dbh | sqlDialect     | sqlAbstract    |
                         tableParent    | viewParent     |
                         statementClass | placeholderPrefix )$/x;
  my ($bad_param) = grep {$_ !~ $regex} keys %params;
  croak "Schema(): invalid parameter: $bad_param" if $bad_param;

  # check or build an instance of SQL::Abstract
  my $sqlAbstr = $params{sqlAbstract} || SQL::Abstract->new;
  $sqlAbstr->isa('SQL::Abstract')
    or croak "arg. to sqlAbstract is not a SQL::Abstract instance";

  # record some schema-specific global variables 
  my $classData = {
    sqlAbstr          => $sqlAbstr,
    columnType        => {}, # {typeName => {handler1 => code1, ...}}
    noUpdateColumns   => [],
    debug             => undef,
    placeholderPrefix => '?',
    dbiPrepareMethod  => 'prepare',
  };
  for my $key (qw/statementClass placeholderPrefix/) {
    $classData->{$key} = $params{$key} if $params{$key};
  }
  for my $key (qw/tableParent viewParent/) {
    my $parent = $params{$key} or next;
    ref $parent or $parent = [$parent];
    $class->_ensureClassLoaded($_) foreach @$parent;
    $classData->{$key} = $parent;
  }

  $class->_setClassData($pckName => $classData);
  $class->_createPackage($pckName => [$class]);

  $pckName->dbh($params{dbh}) if $params{dbh};

  my $stmt_class = $params{statementClass} || 'DBIx::DataModel::Statement';
  $pckName->statementClass($stmt_class);

  # _SqlDialect : needs some reshuffling of args, for backwards compatibility :
  # input : scalar or hashref; output : array
  no warnings 'uninitialized';
  my @dialect_args = 
    reftype($params{sqlDialect}) eq 'HASH' ? %{$params{sqlDialect}}
                                           : $params{sqlDialect} || 'Default';

  $pckName->_SqlDialect(@dialect_args);

  return $pckName;
}



sub _SqlDialect {
  my $class = shift;

  my %props;

  if (@_ == 1) { # dialect supplied as a dialect name
    my $dialect_name = shift;
    my $dialect = $sqlDialects->{$dialect_name} 
      or croak "invalid SQL dialect: $dialect_name";
    foreach my $k (keys %{$sqlDialects->{Default}}) {
      $props{$k} = (exists $dialect->{$k}) ? $dialect->{$k} 
                                           : $sqlDialects->{Default}{$k};
    }
  }
  else {         # dialect supplied as a hashref of properties
    %props = (@_);
    my @invalid = grep {! exists $sqlDialects->{Default}{$_}} keys %props;
    not @invalid
      or croak "invalid argument to SqlDialect: " . join(", ", @invalid);
  }

  # limitOffset supplied either as a dialect name or as a coderef
  if ($props{limitOffset} && ! ref $props{limitOffset}) {
    $props{limitOffset} = $sqlLimitDialects->{$props{limitOffset}};
  }

  # copy into class
  $class->classData->{sqlDialect} = \%props;
}


sub Table {
  my ($class, $table, $db_table, @primKey) = @_;

  # prepend schema name in table name, unless table already contains "::"
  $table =~ /::/ or $table = $class . "::" . $table;

  push @{$class->classData->{tables}}, $table;

  $class->_setClassData($table => {
    schema    => $class,
    db_table  => $db_table,
    columns   => '*',
    primKey   => \@primKey,
  });

  my $isa = $class->classData->{tableParent}
         || ['DBIx::DataModel::Table'];
  $class->_createPackage($table, $isa);
  return $class;
}

sub View {
  my $class = shift;

  # special API if called from STORABLE_thaw, see View.pm
  my $FROM_THAW = $_[0] eq '__FROM_THAW' ? shift : undef;

  # other arguments
  my ($view, $columns, $db_tables, $where, @parentTables) = @_;

  # prepend schema name in class names, unless they already contain "::"
  $_ =~ /::/ or $_ = $class . "::" . $_ for $view, @parentTables;

  # list this new View in Schema classData
  push @{$class->classData->{views}}, $view;

  # setup classData for the new View
  $class->_setClassData($view => {
    schema    	 => $class,
    db_table  	 => $db_tables,
    columns   	 => $columns,
    where     	 => $where,
    parentTables => \@parentTables,
  });

  # setup inheritance 
  my $isa = $class->classData->{viewParent} || ['DBIx::DataModel::View'];
  push @$isa, @parentTables;

  # create or complete the package
  if ($FROM_THAW) {
    # Storable::thaw already created the package; just add @ISA to it
    no strict 'refs';
    @{$view."::ISA"} = @$isa;
  }
  else {
    # normal case: create a new package
    $class->_createPackage($view, $isa);
  }
  return $class;
}



sub Association {
  my ($schema, $args1, $args2) = @_;

  my ($table1, $role1, $multipl1, @cols1) = @$args1;
  my ($table2, $role2, $multipl2, @cols2) = @$args2;

  # prepend schema name in table names, unless they already contain "::"
  $_ =~ /::/ or $_ = $schema . "::" . $_  for $table1, $table2;

  my $implement_assoc = "_Assoc_normal";

  my $many1 = _multipl_max($multipl1) > 1 ? "T" : "F";
  my $many2 = _multipl_max($multipl2) > 1 ? "T" : "F";

  # handle implicit column names
  for ($many1 . $many2) {
    /^TT/ and do {$implement_assoc = "_Assoc_many_many"; 
                  last};
    /^TF/ and do {@cols2 or @cols2 = $table2->primKey;
                  @cols1 or @cols1 = @cols2;
                  last};
    /^FT/ and do {@cols1 or @cols1 = $table1->primKey;
                  @cols2 or @cols2 = @cols1;
                  last};
    /^FF/ and do {@cols1 && @cols2 
                         or croak "Association: columns must be explicit "
                                . "with multiplicities $multipl1 / $multipl2"};
  }
  @cols1 == @cols2 or croak "Association: numbers of columns do not match";

  $schema->$implement_assoc($table1, $role1, $multipl1, \@cols1,
			    $table2,         $multipl2, \@cols2);
  $schema->$implement_assoc($table2, $role2, $multipl2, \@cols2,
			    $table1,         $multipl1, \@cols1);
  return $schema;
}

# Normal Association implementation, when one side is of multiplicity one
sub _Assoc_normal { 
  my ($schema, $table, $role,  $multipl,         $cols_ref,
               $foreign_table, $foreign_multipl, $foreign_cols_ref) = @_;

  return if not $role or $role =~ /^(0|""|''|-+|none)$/; 

  not ref $table and $table->isa('DBIx::DataModel::Table')
    or croak "Association : $table is not a Table class";

  # register join parameters in schema->classData
  my %where;
  @where{@$foreign_cols_ref} = @$cols_ref;
  $schema->classData->{joins}{$foreign_table}{$role} = {
    multiplicity => $multipl,
    table        => $table,
    where        => \%where,
  };

  # if one to many
  if (_multipl_max($multipl) > 1) {

    # install select method into foreign table (meth_name => role to follow)
    $foreign_table->MethodFromJoin($role => $role);

    # build insert method, and install it into foreign table
    my $meth_name = "insert_into_$role";
    $schema->_defineMethod($foreign_table, $meth_name, sub {
      my $self = shift;	# remaining @_ contains refs to records for insert()
      ref($self) or croak "$meth_name cannot be called as class method";

      # add join information into records that will be inserted
      foreach my $record (@_) {

        # if this is a scalar, it's no longer a record, but an arg to insert()
        last if !ref $record; # since args are at the end, we exit the loop

        # check that we won't overwrite existing data
	not (grep {$record->{$_}} @$cols_ref) or
	  croak "args to $meth_name should not contain values in @$cols_ref";

        # insert values for the join
	@{$record}{@$cols_ref} = @{$self}{@$foreign_cols_ref};
      }

      return $table->insert(@_);

    });
  }
  else { # if one or zero to one
    # install select method into foreign table 
    $foreign_table->MethodFromJoin($role => $role, {-resultAs => "firstrow"});
  }

}


# special implementation for many-to-many Association
sub _Assoc_many_many {
  my ($schema, $table, $role,  $multipl,         $cols_ref,
               $foreign_table, $foreign_multipl, $foreign_cols_ref) = @_;

  scalar(@$cols_ref) == 2 or 
    croak "improper number of roles in many-to-many association";
  $foreign_table->MethodFromJoin($role, @$cols_ref);
}


sub Composition {
  my ($schema, $args1, $args2) = @_;

  my ($table1, $role1, $multipl1, @cols1) = @$args1;
  my ($table2, $role2, $multipl2, @cols2) = @$args2;
  _multipl_max($multipl1) == 1
    or croak "max multiplicity of first class in a composition must be 1";
  _multipl_max($multipl2) > 1
    or croak "max multiplicity of second class in a composition must be > 1";

  # prepend schema name in table names, unless they already contain "::"
  $_ =~ /::/ or $_ = $schema . "::" . $_  for $table1, $table2;

  # check for conflicting compositions
  my $component_of = $table2->classData->{component_of} || {};
  while (my ($composite, $multipl) = each %$component_of) {
    _multipl_min($multipl) == 0 
      or croak "$table2 can't be a component of $table1 "
             . "(already component of $composite)";
  }
  $table2->classData->{component_of}{$table1} = $multipl1;

  # implement the association
  $schema->Association($args1, $args2);
  $schema->classData->{joins}{$table1}{$role2}{is_composition} = 1;

  return $schema;
}


sub join {
  my ($class, $table, @roles) = @_;
  my $classData  = $class->classData;
  my $sqlDialect = $classData->{sqlDialect};
  my @view_args  = ();


  # special API if called from STORABLE_thaw, see View.pm
  my $FROM_THAW = $table eq '__FROM_THAW';
  if ($FROM_THAW) {
    my $all_roles = shift @roles;
    $all_roles =~ s/\.pm$//;
    ($table, @roles) = split /(_(?:INNER|LEFT|JOIN)_)/, $all_roles;
    $table =~ s[/][::]g;
    push @view_args, '__FROM_THAW';
  }

  # check arguments
  @roles                             or croak "join: not enough arguments";
  not grep {ref $_} ($table, @roles) or croak "join: improper argument (ref)";

  # prepend schema name in table name, unless table already contains "::"
  $table =~ /::/ or $table = $class . "::" . $table;

  # alias syntax : canonicalize "|" into "_ALIAS_"
  $table =~ s/\|/_ALIAS_/;

  # transform into canonical representation of joins
  my @tmp;
  my $join;
  foreach (@roles) {
    # join connector
    /^(INNER|<=>)$/        and do {$join = "_INNER_"; next};
    /^(LEFT|=>)$/          and do {$join = "_LEFT_";  next};
    /^_(INNER|LEFT|JOIN)_/ and do {$join = $_;        next};
    # otherwise, role name
    my $role = $_;
    $role =~ s/\./_DOT_/;
    $role =~ s/\|/_ALIAS_/;
    push @tmp, ($join || "_JOIN_"), $role;
    undef $join;
  }
  @roles = @tmp;

  my $viewName = join "", "${class}::AutoView::", $table, @roles;

  # 0) do nothing if view was already generated
  {
    no strict 'refs';
    return $viewName if %{$viewName.'::'} and not $FROM_THAW;
  }

  # 1) go through the roles and accumulate information 

  # extract table alias
  my $table_alias;
  $table =~ s/_ALIAS_(.+)$// and $table_alias = $1;
  my $source_info = {table => $table, alias => $table_alias};

  my $sql_table = _tableAlias($sqlDialect, $source_info);

  my ($table_shortname) = ($table =~ /^.*::(.+)$/);
  my @parentTables  = ($table);
  my @primKey       = $table->primKey;
  my %sources;     $sources{$table_alias || $table_shortname} = $source_info;
  my %aliases;     $aliases{$table_alias || $table->db_table} = $source_info; 
  my @seenSources = ($source_info);

  my @innerJoins;
  my @leftJoins;
  my $joinInto = \@innerJoins; # initially
  my $forcedJoin;

 ROLE:
  foreach (@roles) {

    # skip pseudo-roles (join indicators)
    /^_INNER_$/ and do {$forcedJoin = \@innerJoins; next ROLE};
    /^_LEFT_$/  and do {$forcedJoin = \@leftJoins;  next ROLE};
    /^_JOIN_$/  and do {                            next ROLE};

    # decompose  parts of role
    my ($source, $role, $alias) = /^(?:(.+?)(?:_DOT_))?    # $1: optional src
                                    (.+?)                  # $2: role
                                    (?:(?:_ALIAS_)(.+))?$  # $3: optional alias
                                  /x
     or croak "join: incorrect role: $_";

    # build join information
    my $joinData;
    if ($source) {
      $source_info = $sources{$source} 
        or croak "join: unknown source: $source in $_";
      $joinData = $classData->{joins}{$source_info->{table}}{$role};
    }
    else {
    SEEN_TABLE:
      foreach my $seenSource (@seenSources) {
        $source_info = $seenSource;
        $joinData = $classData->{joins}{$source_info->{table}}{$role};
        last SEEN_TABLE if $joinData;
      }
    }
    $joinData or croak "join: role $_ not found";

    if ($forcedJoin) { 
      $joinInto = $forcedJoin;
      # THINK : maybe should not allow forced _INNER_ after an initial _LEFT_
      $forcedJoin = undef;
    }
    elsif (_multipl_min($joinData->{multiplicity}) == 0) {
      $joinInto = \@leftJoins;
    }

    # build SQL join syntax
    my $nextTable    = $joinData->{table};
    my $where        = $joinData->{where};
    my $dbTableLeft  =  $source_info->{alias} 
                     || $source_info->{table}->db_table;
    my $dbTableRight =  $alias
                     || $nextTable->db_table;
    my @criteria     = map {"$dbTableLeft.$_=$dbTableRight.$where->{$_}"} 
                           keys %$where;

    # keep track of this new source in various structures
    my $new_info =  {
      table    => $nextTable,
      cond     => join(" AND ", @criteria),
      alias    => $alias,
    };
    push @$joinInto, $new_info;
    unshift @seenSources, $new_info;
    $sources{$alias || $role} = $new_info;
    $aliases{$dbTableRight}   = $new_info;

    # set table as a parent for the view
    push @parentTables, $nextTable;

    # if 1-to-many, add primKey of nextTable to primKey of this view
    push @primKey, $nextTable->primKey 
      if _multipl_max($joinData->{multiplicity}) > 1;

  } # end foreach (@roles)

  # 2) build SQL, following the joins (first inner joins, then left joins)

  # TODO: DROP THIS STUFF about reordering inner/left joins.
  # It only makes sense if NOT USING join syntax 
  # (i.e. FROM t1, t2, ... WHERE $cond1 AND ...)

  my $where      = {};
  my $sql        = "";

  # deal with inner joins
  if (not @innerJoins) {
    $sql = $sql_table;
  }
  elsif ($sqlDialect->{innerJoin}) {
    $sql = _sqlJoins($sql_table, \@innerJoins, $sqlDialect, "innerJoin");
  }
  else {
    my @db_tables = map {_tableAlias($sqlDialect, $_)} @innerJoins;
    $sql = join ", ", $sql_table, @db_tables;
    $where = join " AND ", map {$_->{cond}} @innerJoins;
  }

  # deal with left joins
  $sql = _sqlJoins($sql, \@leftJoins, $sqlDialect, "leftJoin") if @leftJoins;

  # 3) install the View

  push @view_args, $viewName, '*', $sql, $where, @parentTables;
  $class->View(@view_args);

  # add alias information
  $viewName->classData->{tableAliases} = \%aliases;

  # add primKey information
  $viewName->classData->{primKey} = \@primKey;

  return $viewName;
}

# backwards compatibility : "join" was previously called "ViewFromRoles"
*ViewFromRoles = \&join;


sub ColumnType {
  my ($class, $typeName, @args) = @_;

  $class->classData->{columnHandlers}{$typeName} = {@args};
  return $class;
}



sub Autoload { # forward to Source so that Tables and Views inherit it
  my ($class, $toggle) = @_;
  DBIx::DataModel::Source->Autoload($toggle);
  return $class;
}


#----------------------------------------------------------------------
# RUNTIME METHODS
#----------------------------------------------------------------------

sub dbh {
  my ($class, $dbh, %dbh_options) = @_;
  my $classData = $class->classData;

  # if some args, then this is a "setter" (updating the dbh)
  if (@_ > 1) {

    # also support syntax ->dbh([$dbh, %dbh_options])
    ($dbh, %dbh_options) = @$dbh 
      if $dbh && ref $dbh eq 'ARRAY' && ! keys %dbh_options;

    # forbid change of dbh while doing a transaction
    not $classData->{dbh} or $classData->{dbh}[0]{AutoCommit}
      or croak "cannot change dbh(..) while in a transaction";

    if ($dbh) {
      # $dbh must be a database handle
      $dbh->isa('DBI::db')
        or croak "invalid dbh argument";

      # only accept $dbh with RaiseError set
      $dbh->{RaiseError} 
        or croak "arg to dbh(..) must have RaiseError=1";

      # store the dbh
      $classData->{dbh} = [$dbh, %dbh_options];
    }
    else {
      # $dbh was explicitly undef, so remove previous dbh
      delete $classData->{dbh};
    }
  }

  my $return_dbh = $classData->{dbh} || [];
  return wantarray ? @$return_dbh : $return_dbh->[0];
}



sub statementClass {
  my ($class, $statementClass) = @_;

  if ($statementClass) {
    $class->_ensureClassLoaded($statementClass);
    $class->classData->{statementClass} = $statementClass;
  }
  return $class->classData->{statementClass};
}



sub debug { 
  my ($class, $debug) = @_;
  $class->classData->{debug} = $debug; # will be used by internal _debug
}


sub autoInsertColumns {
  my $class = shift; 
  return @{$class->classData->{autoInsertColumns} || []};
}

sub autoUpdateColumns {
  my $class = shift; 
  return @{$class->classData->{autoUpdateColumns} || []};
}

sub noUpdateColumns {
  my $class = shift; 
  return @{$class->classData->{noUpdateColumns} || []};
}


sub selectImplicitlyFor {
  my $class = shift;

  if (@_) {
    $class->classData->{selectImplicitlyFor} = shift;
  }
  return $class->classData->{selectImplicitlyFor};
}

sub dbiPrepareMethod {
  my $class = shift;

  if (@_) {
    $class->classData->{dbiPrepareMethod} = shift;
  }
  return $class->classData->{dbiPrepareMethod};
}


sub tables {
  my $class = shift;
  return @{$class->classData->{tables}};
}


sub table {
  my ($class, $moniker) = @_;

  # prepend schema name in table name, unless table already contains "::"
  $moniker = $class . "::" . $moniker unless $moniker =~ /::/;
  return $moniker;
}


sub views {
  my $class = shift;
  return @{$class->classData->{views}};
}

sub view {
  my ($class, $moniker) = @_;

  # prepend schema name in table name, unless table already contains "::"
  $moniker = $class . "::" . $moniker unless $moniker =~ /::/;
  return $moniker;
}




my @default_state_components = qw/dbh debug selectImplicitlyFor 
                                  dbiPrepareMethod statementClass/;

sub localizeState {
  my ($class, @components) = @_; 
  @components = @default_state_components unless @components;

  my $class_data  = $class->classData;
  my %saved_state;
  $saved_state{$_} = $class_data->{$_} foreach @components;

  return DBIx::DataModel::Schema::_State->new($class, \%saved_state);
}



sub doTransaction { 
  my ($class, $coderef, @new_dbh) = @_; 

  my $classData        = $class->classData;
  my $transaction_dbhs = $classData->{transaction_dbhs} ||= [];

  # localize the dbh and its options, if so requested. 
  my $local_state = $class->localizeState(qw/dbh/)
    and 
        delete($classData->{dbh}), # cheat so that dbh() does not complain
        $class->dbh(@new_dbh)      # and now update the dbh
    if @new_dbh; # postfix "if" because $local_state must not be in a block

  # check that we have a dbh
  my $dbh = $classData->{dbh}[0]
    or croak "no database handle for transaction";

  # how to call and how to return will depend on context
  my $want = wantarray ? "array" : defined(wantarray) ? "scalar" : "void";
  my $in_context = {
    array  => do {my @array;
                  {call   => sub {@array = $coderef->()}, 
                   return => sub {return @array}}},
    scalar => do {my $scalar;
                  {call   => sub {$scalar = $coderef->()}, 
                   return => sub {return $scalar}}},
    void   =>     {call   => sub {$coderef->()}, 
                   return => sub {return}}
   }->{$want};


  my $begin_work_and_exec = sub {
    # make sure dbh is in transaction mode
    if ($dbh->{AutoCommit}) {
      $dbh->begin_work; # will set AutoCommit to false
      push @$transaction_dbhs, $dbh;
    }

    # do the real work
    $in_context->{call}->();
  };

  if (@$transaction_dbhs) { # if in a nested transaction, just exec
    $begin_work_and_exec->();
  }
  else { # else try to execute and commit in an eval block
    eval {
      # check AutoCommit state
      $dbh->{AutoCommit}
        or croak "dbh was not in Autocommit mode before initial transaction";

      # execute the transaction
      $begin_work_and_exec->();

      # commit all dbhs and then reset the list of dbhs
      $_->commit foreach @$transaction_dbhs;
      delete $classData->{transaction_dbhs};
    };

    # if any error, rollback
    my $err = $@;
    if ($err) {              # the transaction failed
      my @rollback_errs = grep {$_} map {eval{$_->rollback}; $@} 
                                        reverse @$transaction_dbhs;
      delete $classData->{transaction_dbhs};
      DBIx::DataModel::Schema::_Exception->throw($err, @rollback_errs);
    }
  }

  return $in_context->{return}->();
}



sub keepLasth {
  my $class = shift;

  $class->classData->{keepLasth} = shift if @_;
  return $class->classData->{keepLasth};
}


sub lasth {
  my ($class) = @_;
  return $class->classData->{lasth};
}



sub unbless {
  my $class = shift;

  eval "use Acme::Damn (); 1"
    or croak "cannot unbless, Acme::Damn does not seem to be installed";

  _unbless($_) foreach @_;

  return wantarray ? @_ : $_[0];
}



#----------------------------------------------------------------------
# UTILITY METHODS (PRIVATE)
#----------------------------------------------------------------------


sub _createPackage {
  my ($schema, $pckName, $isa_arrayref) = @_;
  no strict 'refs';

  # !(%{$pckName.'::'}) or croak "package $pckName is already defined";
  my $isa = $pckName."::ISA";
  not defined  @{$isa} or croak "won't overwrite $isa";
  @{$isa} = @$isa_arrayref;
  return $pckName;
}



sub _defineMethod {
  my ($schema, $pckName, $methName, $coderef, $silent) = @_;
  my $fullName = $pckName.'::'.$methName;

  no strict 'refs';

  if ($coderef) {
    not defined(&{$fullName})
      or croak "method $fullName is already defined";
    $silent or not $pckName->can($methName)
      or carp "method $methName in $pckName will be overridden";
    *{$fullName} = $coderef;
  }
  else {
    delete ${$pckName.'::'}{$methName};
  }
}


sub _ensureClassLoaded {
  my ($schema, $to_load) = @_;
  no strict 'refs';
  (%{$to_load.'::'}) or eval "require $to_load" 
                     or croak "can't load class $to_load : $@";
}

#----------------------------------------------------------------------
# UTILITY FUNCTIONS (PRIVATE)
#----------------------------------------------------------------------


sub _sqlJoins { # connect a sequence of joins according to SQL dialect
  my ($leftmost, $joins, $dialect, $joinType) = @_;
  # joins is an arrayref of structs {table => , cond => , alias => }

  my $join_syntax = $dialect->{$joinType}
    or croak "no such join type in sqlDialect: $joinType";

  my $sql;

  if ($dialect->{joinAssociativity} eq "right") {
    my $last_join = pop @$joins;
    my $join_on   = $last_join->{cond};
       $sql       = $last_join->{table}->db_table;
    foreach my $operand (reverse @$joins) {
      my $table = _tableAlias($dialect, $operand);
      $sql = sprintf $join_syntax, $table, $sql, $join_on;
      $join_on = $operand->{cond};
    }
    $sql = sprintf $join_syntax, $leftmost, $sql, $join_on;
  } 
  else { # left associativity
    $sql = $leftmost;
    foreach my $operand (@$joins) {
      my $table = _tableAlias($dialect, $operand);
      $sql = sprintf $join_syntax, $sql, $table, $operand->{cond};
    }
  }
  return $sql;
}

sub _tableAlias {
  my ($dialect, $source_info) = @_;
  my $db_table = $source_info->{table}->db_table;
  my $alias    = $source_info->{alias};
  return 
    $alias ? sprintf($dialect->{tableAlias} || "%s AS %s", $db_table, $alias)
           : $db_table;
}


sub _multipl_min {
  my $multiplicity = shift;
  for ($multiplicity) {
    /^(\d+)/ and return $1;
    /^[*n]$/ and return 0;
  }
  croak "illegal multiplicity : $multiplicity";
}

sub _multipl_max {
  my $multiplicity = shift;
  for ($multiplicity) {
    /(\d+)$/ and return $1;
    /[*n]$/  and return POSIX::INT_MAX;
  }
  croak "illegal multiplicity : $multiplicity";
}


sub _unbless {
  my $obj = shift;

  no strict;               # because Acme::Damn will only be loaded on-demand
  Acme::Damn::damn($obj) if blessed $obj;

  for (ref $obj) {
    /^HASH$/  and do {  _unbless($_) foreach values %$obj;  };
    /^ARRAY$/ and do {  _unbless($_) foreach @$obj;         };
  }
}



#----------------------------------------------------------------------
# PRIVATE CLASS FOR LOCALIZING STATE (see L</localizeState> method
#----------------------------------------------------------------------

package DBIx::DataModel::Schema::_State;

sub new {
  my ($class, $schema, $state) = @_;
  bless [$schema, $state], $class;
}


sub DESTROY { # called when the guard goes out of scope
  my ($self) = @_;

  # localize $@, in case we were called while dying - see L<perldoc/Destructors>
  local $@;

  my ($schema, $previous_state) = @$self;

  # must cleanup dbh so that ->dbh(..) does not complain if in a transaction
  if (exists $previous_state->{dbh}) {
    my $classData = $schema->classData;
    delete $classData->{dbh};
  }

  # invoke "setter" method on each state component
  $schema->$_($previous_state->{$_}) foreach keys %$previous_state;
}


#----------------------------------------------------------------------
# PRIVATE CLASS FOR TRANSACTION EXCEPTIONS
#----------------------------------------------------------------------

package DBIx::DataModel::Schema::_Exception;
use strict;
use warnings;

use overload '""' => sub {
  my $self = shift;
  my $err             = $self->initial_error;
  my @rollback_errs   = $self->rollback_errors;
  my $rollback_status = @rollback_errs ? join(", ", @rollback_errs) : "OK";
  return "FAILED TRANSACTION: $err (rollback: $rollback_status)";
};


sub throw {
  my $class = shift;
  my $self = bless [@_], $class;
  die $self;
}

sub initial_error {
  my $self = shift;
  return $self->[0];
}

sub rollback_errors {
  my $self = shift;
  return @$self[1..$#{$self}];
}


1; 

__END__

=head1 NAME

DBIx::DataModel::Schema - Factory for DBIx::DataModel Schemas

=head1 DESCRIPTION

This is the parent class for all schema classes created through

  DBIx::DataModel->Schema($schema_name, ...);

=head1 METHODS

Methods are documented in 
L<DBIx::DataModel::Doc::Reference|DBIx::DataModel::Doc::Reference>.
This module implements

=over

=item L<Schema|DBIx::DataModel::Doc::Reference/Schema>

=item L<Table|DBIx::DataModel::Doc::Reference/Table>

=item L<View|DBIx::DataModel::Doc::Reference/View>

=item L<Association|DBIx::DataModel::Doc::Reference/Association>

=item L<join|DBIx::DataModel::Doc::Reference/join>

=item L<ColumnType|DBIx::DataModel::Doc::Reference/ColumnType>

=item L<dbh|DBIx::DataModel::Doc::Reference/dbh>

=item L<debug|DBIx::DataModel::Doc::Reference/debug>

=item L<noUpdateColumns|DBIx::DataModel::Doc::Reference/noUpdateColumns>

=item L<autoUpdateColumns|DBIx::DataModel::Doc::Reference/autoUpdateColumns>

=item L<selectImplicitlyFor|DBIx::DataModel::Doc::Reference/selectImplicitlyFor>

=item L<dbiPrepareMethod|DBIx::DataModel::Doc::Reference/dbiPrepareMethod>

=item L<tables|DBIx::DataModel::Doc::Reference/tables>

=item L<table|DBIx::DataModel::Doc::Reference/table>

=item L<views|DBIx::DataModel::Doc::Reference/views>

=item L<view|DBIx::DataModel::Doc::Reference/view>

=item L<localizeState|DBIx::DataModel::Doc::Reference/localizeState>

=item L<statementClass|DBIx::DataModel::Doc::Reference/statementClass>

=item L<doTransaction|DBIx::DataModel::Doc::Reference/doTransaction>

=item L<unbless|DBIx::DataModel::Doc::Reference/unbless>

=item L<_createPackage|DBIx::DataModel::Doc::Reference/_createPackage>

=item L<_defineMethod|DBIx::DataModel::Doc::Reference/_defineMethod>

=back

=head1 PRIVATE SUBCLASSES

This module has two internal subclasses.

=head2 _State

A private class for localizing state (using a DESTROY method).

=head2 _Exception

A private class for exceptions during transactions
(see  L<doTransaction|DBIx::DataModel::Doc::Reference/doTransaction>).



=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>

=head1 COPYRIGHT & LICENSE

Copyright 2006, 2008 Laurent Dami.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.





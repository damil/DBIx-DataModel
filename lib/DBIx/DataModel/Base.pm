#----------------------------------------------------------------------
package DBIx::DataModel::Base;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use Carp;

our @CARP_NOT = qw/DBIx::DataModel::Schema DBIx::DataModel::Source
		   DBIx::DataModel::Table  DBIx::DataModel::View   /;

my %classData; # {className => {classProperty => value, ...}}

#----------------------------------------------------------------------
# COMPILE-TIME METHODS
#----------------------------------------------------------------------

{
  my $autoloader = sub {
    my $self = shift;
    my $class = ref($self) || $self;
    my $attribute = our $AUTOLOAD;
    $attribute =~ s/^.*:://;
    return if $attribute eq 'DESTROY'; # won't overload that one!

    return $self->{$attribute} if ref($self) and exists $self->{$attribute};

    croak "no $attribute method in $class"; # otherwise
  };


  sub Autoload { # installs or desinstalls an AUTOLOAD in $package
    my ($class, $toggle) = @_;

    not ref($class)  or croak "Autoload is a class method";
    defined($toggle) or croak "Autoload : missing toggle value";

    DBIx::DataModel::Schema->_defineMethod($class, 'AUTOLOAD', 
					   $toggle ? $autoloader : undef);
  }
}

sub AutoInsertColumns {
  my $self = shift; 
  $self->classData->{autoInsertColumns} = \@_;
}

sub AutoUpdateColumns {
  my $self = shift; 
  $self->classData->{autoUpdateColumns} = \@_;
}

sub NoUpdateColumns {
  my $self = shift; 
  $self->classData->{noUpdateColumns} = \@_;
}



#----------------------------------------------------------------------
# RUNTIME PUBLIC METHODS
#----------------------------------------------------------------------

sub classData {
  my $self = shift;
  my $class = ref($self) || $self;
  return $classData{$class};
}



#----------------------------------------------------------------------
# UTILITY METHODS (PRIVATE, USED BY SUBCLASSES)
#----------------------------------------------------------------------

sub _setClassData {
  my ($class, $subclass, $data_ref) = @_;
  $classData{$subclass} = $data_ref;
}




1; # End of DBIx::DataModel::Base

__END__

=head1 NAME

DBIx::DataModel::Base - Base class for DBIx::DataModel

=head1 DESCRIPTION

This package defines generic methods that will be available
both for 
L<DBIx::DataModel::Schema|DBIx::DataModel::Schema> classes 
and
L<DBIx::DataModel::Table|DBIx::DataModel::Table> classes.


=head1 METHODS

Methods are documented in 
L<DBIx::DataModel::Doc::Reference|DBIx::DataModel::Doc::Reference>.
This module implements

=over

=item L<classData|DBIx::DataModel::Doc::Reference/classData>

=item L<_setClassData|DBIx::DataModel::Doc::Reference/_setClassData>

=item L<Autoload|DBIx::DataModel::Doc::Reference/Autoload>

=item L<AutoInsertColumns|DBIx::DataModel::Doc::Reference/AutoInsertColumns>

=item L<AutoUpdateColumns|DBIx::DataModel::Doc::Reference/AutoUpdateColumns>

=item L<NoUpdateColumns|DBIx::DataModel::Doc::Reference/NoUpdateColumns>

=back

=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 by Laurent Dami.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 


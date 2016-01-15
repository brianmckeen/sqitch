#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More tests => 15;
use Test::Exception;
our $require;

BEGIN {
    $require               = sub { CORE::require(shift) };
    *CORE::GLOBAL::require = sub { $require->(shift) };
}

use App::Sqitch::Engine::mssql;

my $mssql = _get_new_fake_mssql();
is( $mssql->_driver(),              undef,         "Initially driver is undef" );
is( $mssql->_driver("DBD::Sybase"), "DBD::Sybase", "Setting driver returns driver" );
is( $mssql->_driver(),              "DBD::Sybase", "Setting driver actually sets driver" );
throws_ok { $mssql->_driver("DBD::DerpSauce") } qr/Driver must be one of theses DBD modules: DBD::ADO, DBD::ODBC, DBD::Sybase\n/, "Unkknown driver is fatal";

# TODO: test actual App::Sqitch::Engine::mssql->new(_driver => "DBD::ADO")
# {
#     my $mssql = App::Sqitch::Engine::mssql->new( sqitch => $sqitch, _driver => "DBD::ADO", … );
#     is( $mssql->_driver(), "DBD::ADO", "driver can be set via new() attr _driver" );
# }

{
    my $mssql = _get_new_fake_mssql();
    no warnings 'redefine';
    my $und_driver = 0;
    my $use_driver = 0;
    local *App::Sqitch::Engine::mssql::_driver = sub {
        $und_driver++;
        if ( $und_driver == 1 ) {
            return;
        }
        else {
            return "DBD::ADO";
        }
    };
    local *App::Sqitch::Engine::mssql::use_driver = sub { $use_driver++ };

    is( $mssql->driver(), "DBD::ADO", "driver() returns driver" );
    is( $use_driver,      1,          "driver() figures out driver if not already set" );

    is( $mssql->driver(), "DBD::ADO", "driver() still returns driver" );
    is( $use_driver,      1,          "driver() does not figure out driver if already set" );
}

{
    my $mssql = _get_new_fake_mssql();
    $mssql->_driver("DBD::ADO");
    local $require = sub { die "Mocking failure of $_[0]\n" if $_[0] eq "DBD/ADO.pm"; CORE::require( $_[0] ); };
    throws_ok { $mssql->use_driver() } qr/Could not load specified driver: DBD::ADO/, "Specifying an unloadable driver causes use_driver() to fail";
}

{
    local $^O = 'MSWin32';
    my $mssql = _get_new_fake_mssql();
    local $require = sub {
        return 1 if $_[0] eq 'DBD/ADO.pm';
        CORE::require( $_[0] );
    };
    $mssql->use_driver();
    is( $mssql->driver(), "DBD::ADO", "use_driver() does DBD::ADO if DBD::ADO is available on MSWin32 systems" );
}

{
    local $^O = 'DerpOS';
    my $mssql = _get_new_fake_mssql();
    local $require = sub {
        return 1 if $_[0] eq 'DBD/ODBC.pm';
        return 1 if $_[0] eq 'DBD/ADO.pm';
        CORE::require( $_[0] );
    };
    $mssql->use_driver();
    is( $mssql->driver(), "DBD::ODBC", "use_driver() does not DBD::ADO on non-MSWin32 systems" );
}

{
    my $mssql = _get_new_fake_mssql();
    local $require = sub {
        return 1 if $_[0] eq 'DBD/ODBC.pm';
        die "Mocking failure of $_[0]\n" if $_[0] eq "DBD/ADO.pm";
        CORE::require( $_[0] );
    };
    $mssql->use_driver();
    is( $mssql->driver(), "DBD::ODBC", "use_driver() does DBD::ODBC if  DBD::ADO is not available" );
}

{
    my $mssql = _get_new_fake_mssql();
    local $require = sub {
        return 1                         if $_[0] eq 'DBD/Sybase.pm';
        die "Mocking failure of $_[0]\n" if $_[0] eq "DBD/ADO.pm";
        die "Mocking failure of $_[0]\n" if $_[0] eq "DBD/ODBC.pm";
        CORE::require( $_[0] );
    };
    $mssql->use_driver();
    is( $mssql->driver(), "DBD::Sybase", "use_driver() does DBD::Sybase if DBD::ADO and DBD::ODBC are not available" );
}

{
    local $require = sub {
        return 1 if $_[0] eq 'DBD/Sybase.pm';
        return 1 if $_[0] eq "DBD/ADO.pm";
        return 1 if $_[0] eq "DBD/ODBC.pm";
        CORE::require( $_[0] );
    };
    {
        local $^O = 'MSWin32';
        my $mssql = _get_new_fake_mssql();
        $mssql->use_driver();
        is( $mssql->driver(), "DBD::ADO", "use_driver() windows prefers DBD::ADO" );
    }
    {
        local $^O = 'DerpOS';
        my $mssql = _get_new_fake_mssql();
        $mssql->use_driver();
        is( $mssql->driver(), "DBD::ODBC", "use_driver() non-windows prefers DBD::ODBC" );
    }
}

#### utility functions ##

sub _get_new_fake_mssql {
    no warnings 'redefine';
    local *App::Sqitch::Engine::mssql::new = sub { return bless( {}, 'App::Sqitch::Engine::mssql' ) };
    return App::Sqitch::Engine::mssql->new;
}

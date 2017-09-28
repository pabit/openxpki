package OpenXPKI::Server::API2;
use Moose;
use utf8;

=head1 NAME

OpenXPKI::Server::API2 - Standardized internal and external access to sensitive
functions

=cut

# Core modules
use Module::Load;

# CPAN modules
use Module::List qw(list_modules);
use Try::Tiny;

# Project modules
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Server::Log;
use OpenXPKI::Exception;
use OpenXPKI::Server::API2::PluginRole;


=head1 SYNOPSIS

Default usage:

    use OpenXPKI::Server::API2;

    my $api = OpenXPKI::Server::API2->new();
    printf "Available commands: %s\n", join(", ", keys %{$api->commands});

    my $result = $api->dispatch("mycommand", myaction => "go");

To manually register a plugin outside the default namespace:

    my @commands = $api->register_plugin("OpenXPKI::MyAlienplugin");

Set a different plugin namespace for auto-discovery:

    my $api = OpenXPKI::Server::API2->new(
        namespace => "My::Command::Plugins",
    );

Instantiate the API without plugin auto-discovery:

    my $api = OpenXPKI::Server::API2->new(commands => {});

=head1 DESCRIPTION

=head2 Call API commands

This class acts as a dispatcher (single entrypoint) to execute API commands via
L<dispatch>.

It makes available all API commands defined in the C<OpenXPKI::Server::API2::Plugin>
namespace.

=head2 Create a plugin class

Standard (and easy) way to define a new plugin class with API commands:

Create a new package in the C<OpenXPKI::Server::API2::Plugin> namespace (any
deeper hierarchy is OK) and in your package use
L<OpenXPKI::Server::API2::EasyPlugin> as described there.

=cut



=head1 ATTRIBUTES

=head2 log

Optional: L<Log::Log4perl::Logger>. Default: C<CTX('log')-E<gt>application> if
available or a new logger instance.

=cut
has log => (
    is => 'rw',
    isa => 'Log::Log4perl::Logger',
    lazy => 1,
    default => sub {
        my $log = OpenXPKI::Server::Context::hascontext('log') ? CTX('log') : OpenXPKI::Server::Log->new(CONFIG => undef);
        return $log->application,
    },
);

=head2 namespace

Optional: Perl package namespace that will be searched for the command plugins
(classes). Default: C<OpenXPKI::Server::API2::Plugin>

Example:

    my $api = OpenXPKI::Server::API2->new(namespace => "My::App::Command");

=cut
has namespace => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    default => __PACKAGE__."::Plugin",
);

=head2 command_role

Optional: role that all command classes are expected to have. This allows
the API to distinct between command modules that shall be registered and helper
classes. Default: C<OpenXPKI::Server::API2::PluginRole>.

B<ATTENTION>: if you change this make sure the role you specify requires at
least the same methods as L<OpenXPKI::Server::API2::PluginRole>.

=cut
has command_role => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    default => "OpenXPKI::Server::API2::PluginRole",
);

=head2 commands

I<HashRef> containing registered API commands and their Perl packages. The hash
is built on first access, you should rarely have a reason to set this manually.

Structure:

    {
        "API command 1" => "Perl package name",
        "API command 2" => ...,
    }

=head1 METHODS

=head2 add_commands

Register the given C<command =E<gt> package> mappings to the list of known API
commands.

=cut
has commands => (
    is => 'rw',
    isa => 'HashRef[Str]',
    traits => [ 'Hash' ],
    handles => {
        add_commands => 'set',
    },
    lazy => 1,
    builder => "_build_commands",
);

sub _build_commands {
    # Code taken from Plugin::Simple
    my $self = shift;

    my @modules = ();
    my $candidates = {};
    try {
        $candidates = list_modules($self->namespace."::", { list_modules => 1, recurse => 1 });
    }
    catch {
        OpenXPKI::Exception->throw (
            message => "Error listing API plugins",
            params => { namespace => $self->namespace, error => $_ }
        );
    };

    return $self->_load_plugins( [ keys %{ $candidates } ] );
}

#
# Tries to load the given plugin classes.
#
# Returns a HashRef that contains the C<command =E<gt> package> mappings.
#
sub _load_plugins {
    my ($self, $packages) = @_;

    my $cmd_package_map = {};

    for my $pkg (@{ $packages }) {
        my $ok;
        try {
            load $pkg;
            $ok = 1;
        }
        catch {
            $self->log->warn("Error loading API plugin $pkg: $_");
            next;
        };

        if (not $pkg->DOES($self->command_role)) {
            $self->log->debug("API - ignore   $pkg (does not have role ".$self->command_role.")");
            next;
        }

        $self->log->debug("API - register $pkg: ".join(", ", @{ $pkg->commands }));
        # FIXME test for duplicate command names
        $cmd_package_map->{$_} = $pkg for @{ $pkg->commands };
    }

    return $cmd_package_map;
}

=head2 register_plugin

Manually register a plugin class containing API commands.

This is usually not neccessary because plugin classes are auto-discovered
as described L<above|/DESCRIPTION>.

Returns a plain C<list> of API commands that were found.

B<Parameters>

=over

=item * C<$packages> - class/package name I<Str> or I<ArrayRef> of package names

=back

=cut
sub register_plugin {
    my ($self, $packages) = @_;
    $packages = [ $packages ] unless (ref $packages or "") eq "ARRAY";

    my $pkg_by_cmd = $self->_load_plugins($packages);
    $self->add_commands( %{ $pkg_by_cmd } );
    return ( keys %{ $pkg_by_cmd } );
}

=head2 dispatch

Dispatches an API command call to the responsible plugin instance.

B<Parameters>

=over

=item * C<$command> - API command name

=item * C<%params> - Parameter hash

=back

=cut
sub dispatch {
    my ($self, $command, %params) = @_;

    my $package = $self->commands->{$command}
        or OpenXPKI::Exception->throw(
            message => "Unknown API command",
            params => { command => $command }
        );

    # FIXME Implement one-time instantiation
    return $package->new->execute($command, \%params);
}

__PACKAGE__->meta->make_immutable;

=head1 INTERNALS

=head2 Design principles

=over

=item * B<One or more commands per class>: each plugin class can specify one or
more API commands. This allows to keep helper functions that are shared between
several API commands close to the command code. It also helps reducing the
number of individual Perl module files.

=item * B<No base class>: when you use L<OpenXPKI::Server::API2::EasyPlugin> to
define a plugin class all functionality is added via Moose roles instead of
a base class. This allows for plugin classes to be based on any other classes
if needed.

=item * B<Standard magic>: syntactic sugar and helper functions only use Moose's
standard way to e.g. customize meta classes or inject roles. No other black
magic is used.

=item * B<Breakout allowed>: using L<OpenXPKI::Server::API2::EasyPlugin> is not
a must, API plugins might be implemented differently by manually adding the role
L<OpenXPKI::Server::API2::PluginRole> to a plugin class.

=back

=cut

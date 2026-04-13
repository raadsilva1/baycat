#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';
use feature qw(say);
use Gtk3;
use Glib qw(TRUE FALSE);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);

my %APP = (
    project_name => 'neofelis',
    app_name     => 'Neofelis',
    file_name    => 'baycat.pl',
    bin_name     => 'baycat',
    log_dir_name => 'baycat',
);

my %UI;
my %STATE = (
    current           => undef,
    last_good_command => undef,
    selection         => {
        main_output  => undef,
        extra_output => undef,
        arrangement  => 'right',
    },
);

main();
exit 0;

sub main {
    binmode(STDERR, ':encoding(UTF-8)');
    binmode(STDOUT, ':encoding(UTF-8)');

    my $preflight_problem = preflight_environment_problem();
    if ($preflight_problem) {
        print STDERR "$preflight_problem\n";
        exit 1;
    }

    unless (Gtk3->init_check) {
        print STDERR "Neofelis could not open a graphical window. Please run it inside an Artix X11 desktop session.\n";
        exit 1;
    }

    setup_logging();
    log_event('info', 'Application starting.');

    my $dependency_problem = runtime_dependency_problem();
    if ($dependency_problem) {
        show_error_and_exit($dependency_problem);
    }

    my $initial_state = discover_state();
    if (!$initial_state->{ok}) {
        my $message = $initial_state->{user_error}
            || 'Your screens could not be read right now.';
        show_error_and_exit($message);
    }

    if ($initial_state->{active_count} > 0) {
        $STATE{last_good_command} = command_from_state($initial_state);
    }
    $STATE{current} = $initial_state;

    build_ui();
    refresh_ui($initial_state, 'Your screen layout is ready.');
    Gtk3->main;
}

sub preflight_environment_problem {
    return 'Neofelis needs an X11 desktop session. No DISPLAY was found.' if !$ENV{DISPLAY};

    if (($ENV{XDG_SESSION_TYPE} || '') eq 'wayland' && !$ENV{DISPLAY}) {
        return 'Neofelis only works in X11 sessions.';
    }

    return undef;
}

sub runtime_dependency_problem {
    my @missing;
    for my $tool (qw(xrandr)) {
        push @missing, $tool unless command_exists($tool);
    }

    if (@missing) {
        return 'A required tool is missing. Please install xrandr support and try again.';
    }

    return undef;
}

sub build_ui {
    my $window = Gtk3::Window->new('toplevel');
    $window->set_title($APP{app_name});
    $window->set_default_size(960, 700);
    $window->set_border_width(14);
    $window->signal_connect(delete_event => sub { Gtk3->main_quit; return FALSE; });

    my $root = Gtk3::Box->new('vertical', 12);
    $window->add($root);

    my $header = Gtk3::Box->new('vertical', 4);
    my $title = Gtk3::Label->new(undef);
    $title->set_use_markup(TRUE);
    $title->set_markup('<span size="xx-large" weight="bold">Neofelis</span>');
    $title->set_xalign(0);

    my $subtitle = Gtk3::Label->new('A friendly way to manage your screens.');
    $subtitle->set_xalign(0);
    $subtitle->set_line_wrap(TRUE);

    $header->pack_start($title, FALSE, FALSE, 0);
    $header->pack_start($subtitle, FALSE, FALSE, 0);
    $root->pack_start($header, FALSE, FALSE, 0);

    my $status_frame = Gtk3::Frame->new('Current status');
    my $status_box = Gtk3::Box->new('vertical', 6);
    $status_box->set_border_width(10);
    my $status_title = Gtk3::Label->new('');
    $status_title->set_xalign(0);
    $status_title->set_line_wrap(TRUE);
    $status_title->set_use_markup(TRUE);

    my $status_body = Gtk3::Label->new('');
    $status_body->set_xalign(0);
    $status_body->set_line_wrap(TRUE);

    $status_box->pack_start($status_title, FALSE, FALSE, 0);
    $status_box->pack_start($status_body, FALSE, FALSE, 0);
    $status_frame->add($status_box);
    $root->pack_start($status_frame, FALSE, FALSE, 0);

    my $actions_frame = Gtk3::Frame->new('Quick actions');
    my $actions_outer = Gtk3::Box->new('vertical', 10);
    $actions_outer->set_border_width(10);

    my $help = Gtk3::Label->new('Pick the screens you want to use, then choose a simple action.');
    $help->set_xalign(0);
    $help->set_line_wrap(TRUE);
    $actions_outer->pack_start($help, FALSE, FALSE, 0);

    my $grid = Gtk3::Grid->new();
    $grid->set_row_spacing(8);
    $grid->set_column_spacing(8);

    my $main_label = Gtk3::Label->new('Main screen');
    $main_label->set_xalign(0);
    my $extra_label = Gtk3::Label->new('Other screen');
    $extra_label->set_xalign(0);
    my $layout_label = Gtk3::Label->new('Where the other screen goes');
    $layout_label->set_xalign(0);

    my $main_combo = Gtk3::ComboBoxText->new();
    my $extra_combo = Gtk3::ComboBoxText->new();
    my $layout_combo = Gtk3::ComboBoxText->new();

    for my $row (
        ['right', 'To the right'],
        ['left',  'To the left'],
        ['above', 'Above'],
        ['below', 'Below'],
    ) {
        $layout_combo->append($row->[0], $row->[1]);
    }
    $layout_combo->set_active_id('right');

    $grid->attach($main_label,  0, 0, 1, 1);
    $grid->attach($main_combo,  1, 0, 1, 1);
    $grid->attach($extra_label, 0, 1, 1, 1);
    $grid->attach($extra_combo, 1, 1, 1, 1);
    $grid->attach($layout_label, 0, 2, 1, 1);
    $grid->attach($layout_combo, 1, 2, 1, 1);
    $actions_outer->pack_start($grid, FALSE, FALSE, 0);

    my $button_box = Gtk3::FlowBox->new();
    $button_box->set_selection_mode('none');
    $button_box->set_max_children_per_line(3);
    $button_box->set_row_spacing(8);
    $button_box->set_column_spacing(8);

    my $refresh_btn = Gtk3::Button->new('Refresh screens');
    my $laptop_only_btn = Gtk3::Button->new('Use laptop screen only');
    my $external_only_btn = Gtk3::Button->new('Use external screen only');
    my $one_screen_btn = Gtk3::Button->new('Use one screen only');
    my $mirror_btn = Gtk3::Button->new('Show the same picture on both');
    my $separate_btn = Gtk3::Button->new('Use both screens separately');

    for my $btn ($refresh_btn, $laptop_only_btn, $external_only_btn, $one_screen_btn, $mirror_btn, $separate_btn) {
        $button_box->insert($btn, -1);
    }
    $actions_outer->pack_start($button_box, FALSE, FALSE, 0);

    $actions_frame->add($actions_outer);
    $root->pack_start($actions_frame, FALSE, FALSE, 0);

    my $screens_frame = Gtk3::Frame->new('Screens');
    my $screen_scroll = Gtk3::ScrolledWindow->new();
    $screen_scroll->set_policy('automatic', 'automatic');
    $screen_scroll->set_shadow_type('etched-in');
    my $screens_box = Gtk3::Box->new('vertical', 10);
    $screens_box->set_border_width(10);
    $screen_scroll->add($screens_box);
    $screens_frame->add($screen_scroll);
    $root->pack_start($screens_frame, TRUE, TRUE, 0);

    my $feedback = Gtk3::Label->new('');
    $feedback->set_xalign(0);
    $feedback->set_line_wrap(TRUE);
    $root->pack_start($feedback, FALSE, FALSE, 0);

    $main_combo->signal_connect(changed => sub {
        my $active = $main_combo->get_active_id;
        $STATE{selection}->{main_output} = defined $active ? $active : undef;
    });

    $extra_combo->signal_connect(changed => sub {
        my $active = $extra_combo->get_active_id;
        $STATE{selection}->{extra_output} = defined $active ? $active : undef;
    });

    $layout_combo->signal_connect(changed => sub {
        my $active = $layout_combo->get_active_id;
        $STATE{selection}->{arrangement} = $active || 'right';
    });

    $refresh_btn->signal_connect(clicked => sub {
        refresh_from_system('Screen list refreshed.');
    });

    $laptop_only_btn->signal_connect(clicked => sub {
        apply_named_action('laptop_only');
    });

    $external_only_btn->signal_connect(clicked => sub {
        apply_named_action('external_only');
    });

    $one_screen_btn->signal_connect(clicked => sub {
        apply_named_action('one_screen');
    });

    $mirror_btn->signal_connect(clicked => sub {
        apply_named_action('mirror');
    });

    $separate_btn->signal_connect(clicked => sub {
        apply_named_action('separate');
    });

    %UI = (
        window            => $window,
        status_title      => $status_title,
        status_body       => $status_body,
        screens_box       => $screens_box,
        feedback          => $feedback,
        main_combo        => $main_combo,
        extra_combo       => $extra_combo,
        layout_combo      => $layout_combo,
        refresh_btn       => $refresh_btn,
        laptop_only_btn   => $laptop_only_btn,
        external_only_btn => $external_only_btn,
        one_screen_btn    => $one_screen_btn,
        mirror_btn        => $mirror_btn,
        separate_btn      => $separate_btn,
    );

    $window->show_all;
}

sub refresh_ui {
    my ($state, $message) = @_;

    $UI{status_title}->set_markup('<span size="large" weight="bold">' . markup_escape($state->{overview_title}) . '</span>');
    $UI{status_body}->set_text($state->{overview_body});

    populate_combos($state);
    populate_screen_cards($state);
    update_quick_action_sensitivity($state);
    set_feedback($message || '', 0);

    $UI{window}->show_all;
}

sub populate_combos {
    my ($state) = @_;
    my @connected = @{ $state->{connected_outputs} };
    my $main_combo = $UI{main_combo};
    my $extra_combo = $UI{extra_combo};
    my $layout_combo = $UI{layout_combo};

    $main_combo->remove_all;
    $extra_combo->remove_all;

    my $default_main = $STATE{selection}->{main_output} || $state->{primary_id} || ($connected[0] ? $connected[0]->{id} : undef);

    for my $output (@connected) {
        $main_combo->append($output->{id}, $output->{friendly_name});
    }

    if (@connected) {
        my $main_ok = grep { $_->{id} eq ($default_main || '') } @connected;
        $default_main = $connected[0]->{id} if !$main_ok;
        $main_combo->set_active_id($default_main);
        $STATE{selection}->{main_output} = $default_main;
    } else {
        $STATE{selection}->{main_output} = undef;
    }

    $extra_combo->append('__none__', 'No second screen');
    for my $output (@connected) {
        next if defined $default_main && $output->{id} eq $default_main;
        $extra_combo->append($output->{id}, $output->{friendly_name});
    }

    my $default_extra = $STATE{selection}->{extra_output};
    if (!defined $default_extra || $default_extra eq $default_main) {
        my ($candidate) = grep { $_->{id} ne ($default_main || '') } @connected;
        $default_extra = $candidate ? $candidate->{id} : '__none__';
    }

    my $extra_ok = 0;
    if (defined $default_extra) {
        $extra_ok = grep { $_->{id} eq $default_extra } @connected;
        $extra_ok = 1 if $default_extra eq '__none__';
    }
    $default_extra = '__none__' if !$extra_ok;
    $extra_combo->set_active_id($default_extra);
    $STATE{selection}->{extra_output} = $default_extra;

    my $arrangement = $STATE{selection}->{arrangement} || 'right';
    $layout_combo->set_active_id($arrangement);
    $STATE{selection}->{arrangement} = $arrangement;
}

sub populate_screen_cards {
    my ($state) = @_;
    my $box = $UI{screens_box};

    for my $child ($box->get_children) {
        $box->remove($child);
    }

    for my $output (@{ $state->{outputs} }) {
        my $frame = Gtk3::Frame->new(undef);
        my $card = Gtk3::Box->new('vertical', 8);
        $card->set_border_width(10);

        my $name = Gtk3::Label->new(undef);
        $name->set_use_markup(TRUE);
        $name->set_markup('<span weight="bold" size="large">' . markup_escape($output->{friendly_name}) . '</span>');
        $name->set_xalign(0);

        my $secondary = Gtk3::Label->new($output->{id});
        $secondary->set_xalign(0);

        my $desc = Gtk3::Label->new(screen_blurb($state, $output));
        $desc->set_xalign(0);
        $desc->set_line_wrap(TRUE);

        my $buttons = Gtk3::FlowBox->new();
        $buttons->set_selection_mode('none');
        $buttons->set_max_children_per_line(3);
        $buttons->set_row_spacing(6);
        $buttons->set_column_spacing(6);

        if ($output->{connected}) {
            my $use_only = Gtk3::Button->new('Use only this screen');
            $use_only->signal_connect(clicked => sub {
                apply_per_output_action('use_only', $output->{id});
            });
            $buttons->insert($use_only, -1);

            if ($output->{active} && !$output->{primary}) {
                my $make_main = Gtk3::Button->new('Make main screen');
                $make_main->signal_connect(clicked => sub {
                    apply_per_output_action('make_main', $output->{id});
                });
                $buttons->insert($make_main, -1);
            }

            if ($output->{active} && $state->{active_count} > 1) {
                my $turn_off = Gtk3::Button->new('Turn this screen off');
                $turn_off->signal_connect(clicked => sub {
                    apply_per_output_action('turn_off', $output->{id});
                });
                $buttons->insert($turn_off, -1);
            }
        }

        $card->pack_start($name, FALSE, FALSE, 0);
        $card->pack_start($secondary, FALSE, FALSE, 0);
        $card->pack_start($desc, FALSE, FALSE, 0);
        $card->pack_start($buttons, FALSE, FALSE, 0);
        $frame->add($card);
        $box->pack_start($frame, FALSE, FALSE, 0);
    }
}

sub update_quick_action_sensitivity {
    my ($state) = @_;
    my $connected_count = scalar @{ $state->{connected_outputs} };

    my $have_laptop = defined $state->{laptop_output};
    my $have_external = defined $state->{first_external_output};

    $UI{laptop_only_btn}->set_sensitive($have_laptop ? TRUE : FALSE);
    $UI{external_only_btn}->set_sensitive($have_external ? TRUE : FALSE);
    $UI{one_screen_btn}->set_sensitive($connected_count >= 1 ? TRUE : FALSE);
    $UI{mirror_btn}->set_sensitive($connected_count >= 2 ? TRUE : FALSE);
    $UI{separate_btn}->set_sensitive($connected_count >= 2 ? TRUE : FALSE);
    $UI{main_combo}->set_sensitive($connected_count >= 1 ? TRUE : FALSE);
    $UI{extra_combo}->set_sensitive($connected_count >= 2 ? TRUE : FALSE);
    $UI{layout_combo}->set_sensitive($connected_count >= 2 ? TRUE : FALSE);
}

sub refresh_from_system {
    my ($message) = @_;
    my $state = discover_state();

    if (!$state->{ok}) {
        set_feedback($state->{user_error} || 'Your screens could not be read right now.', 1);
        return;
    }

    $STATE{current} = $state;
    if ($state->{active_count} > 0) {
        $STATE{last_good_command} = command_from_state($state);
    }
    refresh_ui($state, $message);
}

sub apply_named_action {
    my ($action) = @_;
    my $before = discover_state();
    if (!$before->{ok}) {
        set_feedback($before->{user_error} || 'Your screens could not be read right now.', 1);
        return;
    }

    my ($ok, $args, $message) = build_named_action($before, $action);
    if (!$ok) {
        set_feedback($message, 1);
        return;
    }

    apply_xrandr_change($before, $args);
}

sub apply_per_output_action {
    my ($action, $output_id) = @_;
    my $before = discover_state();
    if (!$before->{ok}) {
        set_feedback($before->{user_error} || 'Your screens could not be read right now.', 1);
        return;
    }

    my ($ok, $args, $message) = build_per_output_action($before, $action, $output_id);
    if (!$ok) {
        set_feedback($message, 1);
        return;
    }

    apply_xrandr_change($before, $args);
}

sub apply_xrandr_change {
    my ($before, $args) = @_;
    my $restore = command_from_state($before);

    log_event('info', 'Applying xrandr change: ' . join(' ', map { quotemeta($_) } @$args));
    my ($ok, $stdout, $stderr, $status) = run_command(['xrandr', @$args]);

    if (!$ok) {
        log_event('error', "xrandr failed with status $status: $stderr");
        safe_restore($restore);
        refresh_from_system('That screen setup could not be applied. Your earlier layout was kept.');
        return;
    }

    my $after = discover_state();
    if (!$after->{ok} || $after->{active_count} < 1) {
        log_event('error', 'New layout was not safe after apply; restoring last good layout.');
        safe_restore($restore);
        refresh_from_system('That screen setup could not be applied safely. Your earlier layout was kept.');
        return;
    }

    $STATE{current} = $after;
    $STATE{last_good_command} = command_from_state($after);
    refresh_ui($after, success_message_for_state($after));
}

sub safe_restore {
    my ($restore_args) = @_;
    return if !$restore_args || ref($restore_args) ne 'ARRAY' || !@$restore_args;

    my ($ok, $stdout, $stderr, $status) = run_command(['xrandr', @$restore_args]);
    if (!$ok) {
        log_event('error', "Restore attempt failed with status $status: $stderr");
    } else {
        log_event('info', 'Previous layout restored.');
    }
}

sub build_named_action {
    my ($state, $action) = @_;

    if ($action eq 'laptop_only') {
        my $id = $state->{laptop_output};
        return (0, undef, 'No laptop screen was found.') if !$id;
        return build_use_only_action($state, $id);
    }

    if ($action eq 'external_only') {
        my $id = $state->{first_external_output};
        return (0, undef, 'No external monitor was found.') if !$id;
        return build_use_only_action($state, $id);
    }

    if ($action eq 'one_screen') {
        my $main = $STATE{selection}->{main_output};
        return (0, undef, 'Pick the screen you want to keep on.') if !$main;
        return build_use_only_action($state, $main);
    }

    if ($action eq 'mirror') {
        my $main = $STATE{selection}->{main_output};
        my $extra = $STATE{selection}->{extra_output};
        return build_mirror_action($state, $main, $extra);
    }

    if ($action eq 'separate') {
        my $main = $STATE{selection}->{main_output};
        my $extra = $STATE{selection}->{extra_output};
        my $arrangement = $STATE{selection}->{arrangement} || 'right';
        return build_separate_action($state, $main, $extra, $arrangement);
    }

    return (0, undef, 'That action is not available right now.');
}

sub build_per_output_action {
    my ($state, $action, $output_id) = @_;

    if ($action eq 'use_only') {
        return build_use_only_action($state, $output_id);
    }

    if ($action eq 'make_main') {
        return build_make_main_action($state, $output_id);
    }

    if ($action eq 'turn_off') {
        return build_turn_off_action($state, $output_id);
    }

    return (0, undef, 'That action is not available right now.');
}

sub build_use_only_action {
    my ($state, $target_id) = @_;
    my $target = output_by_id($state, $target_id);
    return (0, undef, 'That screen is not available right now.') if !$target || !$target->{connected};

    my @args;
    for my $output (@{ $state->{connected_outputs} }) {
        push @args, '--output', $output->{id};
        if ($output->{id} eq $target_id) {
            push_mode_args(\@args, $target);
            push @args, '--primary';
        } else {
            push @args, '--off';
        }
    }

    return (1, \@args, undef);
}

sub build_make_main_action {
    my ($state, $target_id) = @_;
    my $target = output_by_id($state, $target_id);
    return (0, undef, 'That screen is not available right now.') if !$target || !$target->{connected};
    return (0, undef, 'Turn this screen on first.') if !$target->{active};

    return (1, ['--output', $target_id, '--primary'], undef);
}

sub build_turn_off_action {
    my ($state, $target_id) = @_;
    my $target = output_by_id($state, $target_id);
    return (0, undef, 'That screen is not available right now.') if !$target || !$target->{connected};
    return (0, undef, 'This screen is already off.') if !$target->{active};
    return (0, undef, 'At least one screen needs to stay on.') if $state->{active_count} <= 1;

    return (1, ['--output', $target_id, '--off'], undef);
}

sub build_mirror_action {
    my ($state, $main_id, $extra_id) = @_;
    return (0, undef, 'Pick the main screen first.') if !$main_id;
    return (0, undef, 'Pick a second screen for mirroring.') if !defined($extra_id) || $extra_id eq '';
    return (0, undef, 'Choose two different screens.') if $main_id eq $extra_id;

    my $main = output_by_id($state, $main_id);
    my $extra = output_by_id($state, $extra_id);
    return (0, undef, 'One of those screens is not available right now.') if !$main || !$extra || !$main->{connected} || !$extra->{connected};

    my $mode = best_common_mode($main, $extra);
    return (0, undef, 'These screens do not share a safe picture size for mirroring.') if !$mode;

    my @args = ('--output', $main_id, '--mode', $mode, '--primary');
    push @args, '--output', $extra_id, '--mode', $mode, '--same-as', $main_id;

    for my $output (@{ $state->{connected_outputs} }) {
        next if $output->{id} eq $main_id || $output->{id} eq $extra_id;
        push @args, '--output', $output->{id}, '--off';
    }

    return (1, \@args, undef);
}

sub build_separate_action {
    my ($state, $main_id, $extra_id, $arrangement) = @_;
    return (0, undef, 'Pick the main screen first.') if !$main_id;
    return (0, undef, 'Pick a second screen to use beside it.') if !defined($extra_id) || $extra_id eq '';
    return (0, undef, 'Choose two different screens.') if $main_id eq $extra_id;

    my $main = output_by_id($state, $main_id);
    my $extra = output_by_id($state, $extra_id);
    return (0, undef, 'One of those screens is not available right now.') if !$main || !$extra || !$main->{connected} || !$extra->{connected};

    my %relation = (
        right => '--right-of',
        left  => '--left-of',
        above => '--above',
        below => '--below',
    );

    my $place = $relation{$arrangement || 'right'} || '--right-of';
    my @args = ('--output', $main_id);
    push_mode_args(\@args, $main);
    push @args, '--primary';

    push @args, '--output', $extra_id;
    push_mode_args(\@args, $extra);
    push @args, $place, $main_id;

    for my $output (@{ $state->{connected_outputs} }) {
        next if $output->{id} eq $main_id || $output->{id} eq $extra_id;
        push @args, '--output', $output->{id}, '--off';
    }

    return (1, \@args, undef);
}

sub push_mode_args {
    my ($args, $output, $forced_mode) = @_;
    my $mode = $forced_mode || $output->{current_mode} || $output->{preferred_mode};
    if ($mode) {
        push @$args, '--mode', $mode;
    } else {
        push @$args, '--auto';
    }
}

sub best_common_mode {
    my ($a, $b) = @_;
    my %seen = map { $_ => 1 } @{ $a->{modes} || [] };
    my @common = grep { $seen{$_} } @{ $b->{modes} || [] };

    return undef if !@common;

    my %preferred = map { $_ => 1 } grep { defined && length } ($a->{preferred_mode}, $b->{preferred_mode}, $a->{current_mode}, $b->{current_mode});
    my @preferred_common = grep { $preferred{$_} } @common;
    @common = @preferred_common if @preferred_common;

    @common = sort {
        mode_score($b) <=> mode_score($a) || $a cmp $b
    } @common;

    return $common[0];
}

sub mode_score {
    my ($mode) = @_;
    return 0 if !$mode || $mode !~ /^(\d+)x(\d+)$/;
    return ($1 * $2);
}

sub discover_state {
    my ($ok, $stdout, $stderr, $status) = run_command(['xrandr', '--query']);
    if (!$ok) {
        log_event('error', "Unable to read xrandr state. status=$status stderr=$stderr");
        return {
            ok         => 0,
            user_error => 'Your screens could not be read right now. Please make sure you are inside an X11 session.',
        };
    }

    my $outputs = parse_xrandr_output($stdout);
    my $state = build_state_from_outputs($outputs);
    $state->{ok} = 1;
    $state->{raw} = $stdout;
    return $state;
}

sub parse_xrandr_output {
    my ($text) = @_;
    my @outputs;
    my $current;

    for my $line (split /\n/, $text) {
        next if $line =~ /^Screen\s+\d+/;

        if ($line =~ /^(\S+)\s+(connected|disconnected)(?:\s+primary)?(?:\s+(\d+x\d+)\+(-?\d+)\+(-?\d+))?/) {
            my ($id, $status, $mode, $x, $y) = ($1, $2, $3, $4, $5);
            my $primary = $line =~ /\bprimary\b/ ? 1 : 0;
            $current = {
                id             => $id,
                connected      => ($status eq 'connected') ? 1 : 0,
                active         => defined $mode ? 1 : 0,
                primary        => $primary,
                current_mode   => $mode,
                preferred_mode => undef,
                x              => defined $x ? $x + 0 : undef,
                y              => defined $y ? $y + 0 : undef,
                modes          => [],
                kind           => output_kind($id),
            };
            push @outputs, $current;
            next;
        }

        if ($current && $line =~ /^\s+(\d+x\d+)\s+(.+)$/) {
            my ($mode, $rest) = ($1, $2);
            push @{ $current->{modes} }, $mode if !grep { $_ eq $mode } @{ $current->{modes} };
            $current->{preferred_mode} ||= $mode if $rest =~ /\+/;
            $current->{current_mode} = $mode if $rest =~ /\*/;
            next;
        }

        $current = undef if $line !~ /^\s/;
    }

    assign_friendly_names(\@outputs);
    return \@outputs;
}

sub build_state_from_outputs {
    my ($outputs) = @_;
    my @connected = grep { $_->{connected} } @$outputs;
    my @active = grep { $_->{active} } @connected;
    my @external = grep { $_->{kind} ne 'laptop' } @connected;

    my $mirrored = 0;
    if (@active > 1) {
        my $all_same_pos = 1;
        my $first = $active[0];
        for my $output (@active[1 .. $#active]) {
            if (!defined $output->{x} || !defined $output->{y} || !defined $first->{x} || !defined $first->{y}) {
                $all_same_pos = 0;
                last;
            }
            if ($output->{x} != $first->{x} || $output->{y} != $first->{y}) {
                $all_same_pos = 0;
                last;
            }
        }
        $mirrored = $all_same_pos ? 1 : 0;
    }

    my ($primary) = grep { $_->{primary} && $_->{active} } @connected;
    $primary ||= (grep { $_->{primary} } @connected)[0];
    $primary ||= $active[0] || $connected[0];

    my ($laptop) = grep { $_->{kind} eq 'laptop' } @connected;
    my ($first_external) = @external;

    my ($overview_title, $overview_body) = overview_for_state(\@connected, \@active, $mirrored, $primary);

    return {
        outputs               => $outputs,
        connected_outputs     => \@connected,
        active_outputs        => \@active,
        active_count          => scalar @active,
        connected_count       => scalar @connected,
        mirrored              => $mirrored,
        primary_id            => $primary ? $primary->{id} : undef,
        laptop_output         => $laptop ? $laptop->{id} : undef,
        first_external_output => $first_external ? $first_external->{id} : undef,
        overview_title        => $overview_title,
        overview_body         => $overview_body,
    };
}

sub overview_for_state {
    my ($connected, $active, $mirrored, $primary) = @_;

    if (!@$connected) {
        return (
            'No screen was found.',
            'Plug in a screen or refresh the list if you just connected one.',
        );
    }

    if (!@$active) {
        return (
            'No screen is active right now.',
            'Try turning on one screen only to get back to a simple layout.',
        );
    }

    if (@$active == 1) {
        my $only = $active->[0];
        my $title = $only->{friendly_name} . ' is active.';
        my $body = $only->{kind} eq 'laptop'
            ? 'Only your laptop screen is on right now.'
            : 'Only one screen is on right now.';
        if ($primary) {
            $body .= ' This is your main screen.';
        }
        return ($title, $body);
    }

    if ($mirrored) {
        my $title = @$active == 2
            ? 'Both screens are showing the same picture.'
            : 'Several screens are showing the same picture.';
        my $body = $primary
            ? $primary->{friendly_name} . ' is your main screen.'
            : 'You can change the main screen at any time.';
        return ($title, $body);
    }

    my $title = scalar(@$active) == 2
        ? 'Two screens are active.'
        : scalar(@$active) . ' screens are active.';
    my $body = 'They are being used separately.';
    if ($primary) {
        $body .= ' ' . $primary->{friendly_name} . ' is the main screen.';
    }
    return ($title, $body);
}

sub screen_blurb {
    my ($state, $output) = @_;

    if (!$output->{connected}) {
        return 'Not connected right now.';
    }

    my @parts;
    if ($output->{active}) {
        push @parts, 'Connected and on.';
        push @parts, 'Main screen.' if $output->{primary};
        if ($state->{active_count} > 1) {
            push @parts, $state->{mirrored}
                ? 'Showing the same picture as another screen.'
                : 'Used together with another screen.';
        }
        if ($output->{current_mode}) {
            push @parts, 'Picture size: ' . $output->{current_mode} . '.';
        }
    } else {
        push @parts, 'Connected but currently off.';
    }

    push @parts, $output->{kind} eq 'laptop' ? 'This is the laptop screen.' : 'This is an external screen.';
    return join(' ', @parts);
}

sub output_by_id {
    my ($state, $output_id) = @_;
    return undef if !$state || !$output_id;
    for my $output (@{ $state->{outputs} || [] }) {
        return $output if $output->{id} eq $output_id;
    }
    return undef;
}

sub command_from_state {
    my ($state) = @_;
    return [] if !$state;

    my @args;
    for my $output (@{ $state->{connected_outputs} || [] }) {
        push @args, '--output', $output->{id};
        if ($output->{active}) {
            push_mode_args(\@args, $output);
            push @args, '--primary' if $output->{primary};
            if (defined $output->{x} && defined $output->{y}) {
                push @args, '--pos', $output->{x} . 'x' . $output->{y};
            }
        } else {
            push @args, '--off';
        }
    }

    return \@args;
}

sub output_kind {
    my ($id) = @_;
    return 'laptop'     if $id =~ /^(?:eDP|LVDS|DSI)/i;
    return 'hdmi'       if $id =~ /^HDMI/i;
    return 'displayport' if $id =~ /^(?:DP|DisplayPort)/i;
    return 'dvi'        if $id =~ /^DVI/i;
    return 'vga'        if $id =~ /^VGA/i;
    return 'other';
}

sub assign_friendly_names {
    my ($outputs) = @_;
    my %base_count;
    my %base_seen;

    for my $output (@$outputs) {
        my $base = friendly_base_name($output->{kind});
        $base_count{$base}++;
    }

    for my $output (@$outputs) {
        my $base = friendly_base_name($output->{kind});
        $base_seen{$base}++;
        my $name = $base;
        if ($base_count{$base} > 1) {
            $name .= ' ' . $base_seen{$base};
        }
        $output->{friendly_name} = $name;
    }
}

sub friendly_base_name {
    my ($kind) = @_;
    return 'Laptop Screen'     if $kind eq 'laptop';
    return 'HDMI Monitor'      if $kind eq 'hdmi';
    return 'DisplayPort Monitor' if $kind eq 'displayport';
    return 'DVI Monitor'       if $kind eq 'dvi';
    return 'VGA Monitor'       if $kind eq 'vga';
    return 'External Monitor';
}

sub success_message_for_state {
    my ($state) = @_;
    return $state->{overview_title} . ' ' . $state->{overview_body};
}

sub set_feedback {
    my ($message, $is_error) = @_;
    my $safe = $message || '';
    my $markup = $is_error
        ? '<span foreground="#9a1b1b" weight="bold">' . markup_escape($safe) . '</span>'
        : '<span foreground="#245c2a">' . markup_escape($safe) . '</span>';
    $UI{feedback}->set_use_markup(TRUE);
    $UI{feedback}->set_markup($markup);
}

sub show_error_and_exit {
    my ($message) = @_;
    my $dialog = Gtk3::MessageDialog->new(
        undef,
        ['destroy-with-parent'],
        'error',
        'close',
        $message,
    );
    $dialog->run;
    $dialog->destroy;
    exit 1;
}

sub command_exists {
    my ($command) = @_;
    for my $dir (split /:/, ($ENV{PATH} || '')) {
        next if !$dir;
        my $candidate = File::Spec->catfile($dir, $command);
        return 1 if -x $candidate && !-d $candidate;
    }
    return 0;
}

sub run_command {
    my ($argv) = @_;
    my $stderr_fh = gensym;
    my $stdout_fh;

    my $pid = eval { open3(undef, $stdout_fh, $stderr_fh, @$argv) };
    if ($@) {
        return (0, '', $@, 255);
    }

    my $stdout = do {
        local $/;
        defined $stdout_fh ? (<$stdout_fh> // '') : '';
    };
    my $stderr = do {
        local $/;
        defined $stderr_fh ? (<$stderr_fh> // '') : '';
    };

    waitpid($pid, 0);
    my $status = $? >> 8;
    return ($status == 0 ? 1 : 0, $stdout, $stderr, $status);
}

sub markup_escape {
    my ($text) = @_;
    $text = '' if !defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}

sub setup_logging {
    my $base = $ENV{XDG_STATE_HOME} || File::Spec->catdir($ENV{HOME} || '.', '.local', 'state');
    my $dir = File::Spec->catdir($base, $APP{log_dir_name});
    eval { make_path($dir) if !-d $dir; };
    return if $@;
    $STATE{log_file} = File::Spec->catfile($dir, 'baycat.log');
}

sub log_event {
    my ($level, $message) = @_;
    my $file = $STATE{log_file} || return;
    my $stamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    if (open my $fh, '>>', $file) {
        print {$fh} "[$stamp] [$level] $message\n";
        close $fh;
    }
}

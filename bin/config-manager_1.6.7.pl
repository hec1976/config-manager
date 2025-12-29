#!/usr/bin/env perl
# Config Manager — REST (actions schema, umask-first, hardened)
# Version: 1.6.7 (2025-12-29)
#
# Changelog 1.6.7:
# - UPGRADE: Log::Log4perl durch Mojo::Log ersetzt (bessere Integration, weniger Abhängigkeiten)
# - REFACTOR: Code alkalisiert (konsistente Formatierung, bessere Lesbarkeit)
# - REFACTOR: Subroutinen modularisiert und logisch geordnet
# - REFACTOR: Fehlerbehandlung und Logging vereinheitlicht
# - KEEP: Alle Features und Fixes aus v1.6.6

use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::Log;
use JSON::MaybeXS qw(encode_json decode_json);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use Time::Piece;
use Time::HiRes qw(time);
use FindBin qw($Bin);
use File::Temp qw(tempfile);
use Fcntl qw(:DEFAULT :mode :flock O_RDONLY);
use Net::CIDR ();
use IPC::Open3 qw(open3);
use Symbol 'gensym';
use Cwd qw(getcwd realpath);
use Text::ParseWords qw(shellwords);
use POSIX qw(:sys_wait_h WNOHANG);

# ---------------- Umask (grundlegend) ----------------
umask 0007;

# ---------------- Version & Globale Variablen ----------------
my $VERSION = '1.6.7';

my $globalfile  = "$Bin/global.json";
my $configsfile = "$Bin/configs.json";

# ---------------- Systemctl (konfigurierbar) ----------------
my $SYSTEMCTL       = '/usr/bin/systemctl';
my $SYSTEMCTL_FLAGS = '';

# ---------------- Logging (Mojolicious) ----------------
my $log = Mojo::Log->new;
$log->level('info');

# ---------------- Konfiguration laden ----------------
sub read_all {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Kann $path nicht lesen: $!";
    local $/; my $data = <$fh>;
    close $fh;
    return $data;
}

my $global = eval { decode_json(read_all($globalfile)) };
die "global.json ungültig: $@" if $@ || ref($global) ne 'HASH';

my $configs = eval { decode_json(read_all($configsfile)) };
die "configs.json ungültig: $@" if $@ || ref($configs) ne 'HASH';

# Systemctl-Konfiguration überschreiben, falls definiert
$SYSTEMCTL       = $global->{systemctl}       if defined $global->{systemctl}       && $global->{systemctl} ne '';
$SYSTEMCTL_FLAGS = exists $ENV{SYSTEMCTL_FLAGS} ? $ENV{SYSTEMCTL_FLAGS}
                : (defined $global->{systemctl_flags} ? $global->{systemctl_flags} : '');

# ---------------- Logging-Konfiguration ----------------
my $logfile = $global->{logfile} // "/var/log/mmbb/config-manager.log";
my $logdir  = dirname($logfile);

# Log-Verzeichnis erstellen, falls nicht vorhanden
if (!-d $logdir) {
    eval { mkdir $logdir, 0755; 1 };
}

if (-d $logdir) {
    $log->path($logfile);
    $log->info("Logging in Datei $logfile aktiviert.");
} else {
    $log->warn("Konnte Log-Verzeichnis $logdir nicht nutzen. Logging auf STDERR.");
}
# ---------------- Mojolicious Secrets ----------------
my $sec = $global->{secret};
my @secrets = ref($sec) eq 'ARRAY' ? @$sec : ($sec // 'change-this-long-random-secret-please');
app->secrets(\@secrets);

if (grep { defined($_) && $_ eq 'change-this-long-random-secret-please' } @secrets) {
    $log->warn('[config-manager] WARNING: Standard-Mojolicious Secret wird verwendet! Bitte in global.json anpassen.');
}

# ---------------- Security & Verzeichnisse ----------------
my $api_token   = defined $ENV{API_TOKEN} && $ENV{API_TOKEN} ne '' ? $ENV{API_TOKEN} : $global->{api_token};
my $allowed_ips = $global->{allowed_ips} // [];
$allowed_ips = [] unless ref($allowed_ips) eq 'ARRAY';

my $tmpDir     = $global->{tmpDir}     // "$Bin/tmp";
my $backupRoot = $global->{backupDir}  // "$Bin/backup";

# Verzeichnisse erstellen, falls nicht vorhanden
unless (-d $backupRoot) { mkdir $backupRoot, 0750 or die "Backup-Verzeichnis $backupRoot fehlt/nicht erstellbar"; }
unless (-d $tmpDir)     { mkdir $tmpDir,     0750 or die "Tmp-Verzeichnis $tmpDir fehlt/nicht erstellbar"; }

my $maxBackups          = $global->{maxBackups} // 10;
my $path_guard          = lc($ENV{PATH_GUARD} // ($global->{path_guard} // 'off'));
my $apply_meta_enabled  = $global->{apply_meta}           // 0;
my $auto_create_backups = $global->{auto_create_backups}  // 0;
my $fsync_dir_enabled   = $global->{fsync_dir}            // 0;

# ---------------- Erlaubte Pfadwurzeln ----------------
my @ALLOWED_CANON = ();
if (ref($global->{allowed_roots}) eq 'ARRAY') {
    my %seen;
    for my $r (@{ $global->{allowed_roots} }) {
        for my $cr (_canon_root($r)) {
            next if $seen{$cr}++;
            push @ALLOWED_CANON, $cr;
        }
    }
}
if (@ALLOWED_CANON) { $log->info('ALLOWED_ROOTS=' . join(',', @ALLOWED_CANON)); }
else { $log->info('ALLOWED_ROOTS=(leer)'); }

# ==================================================
# HILFSFUNKTIONEN
# ==================================================

# --- Pfad-Kanonisierung ---
sub _canon_root {
    my ($p) = @_;
    return () unless defined $p && length $p;
    my $rp = realpath($p);
    return () unless defined $rp && length $rp;
    $rp =~ s{/*$}{};
    $rp .= '/';
    return $rp;
}

sub _canon_dir_of_path {
    my ($p) = @_;
    return () unless defined $p && length $p;
    my $rp = -e $p ? realpath($p) : realpath(dirname($p));
    return () unless defined $rp && length $rp;
    $rp =~ s{/*$}{};
    $rp .= '/';
    return $rp;
}

# --- Berechtigungen ---
sub _mode_str {
    my ($path) = @_;
    return undef unless -e $path;
    my $m = (stat($path))[2];
    return sprintf('%04o', S_IMODE($m));
}

sub _cur_umask {
    my $o = umask();
    umask($o);
    return $o;
}

# --- fsync für Verzeichnisse ---
sub _fsync_dir {
    return unless $fsync_dir_enabled;
    my ($path) = @_;
    my $dir = dirname($path);
    sysopen(my $dh, $dir, O_RDONLY) or return;
    eval { POSIX::fsync(fileno($dh)); };
    close $dh;
}

# --- Pfadprüfung ---
sub _is_allowed_path {
    my ($p) = @_;
    return 0 if -l $p;
    return 1 if $path_guard eq 'off';

    return ($path_guard eq 'audit')
        ? do { $log->warn("PATH-GUARD audit: keine allowed_roots"); 1 }
        : 0
        unless @ALLOWED_CANON;

    my $dircanon = _canon_dir_of_path($p);
    return 0 unless $dircanon;

    for my $root (@ALLOWED_CANON) {
        return 1 if ($dircanon eq $root) || (index($dircanon, $root) == 0);
    }

    if ($path_guard eq 'audit') {
        $log->warn("PATH-GUARD audit: $p außerhalb allowed_roots");
        return 1;
    }
    return 0;
}

# --- Benutzer/Gruppen-IDs ---
sub _name2uid { my ($n)=@_; return undef unless defined $n && length $n; return $n =~ /^\d+$/ ? 0+$n : scalar((getpwnam($n))[2]); }
sub _name2gid { my ($n)=@_; return undef unless defined $n && length $n; return $n =~ /^\d+$/ ? 0+$n : scalar((getgrnam($n))[2]); }

# --- Metadaten anwenden ---
sub _apply_meta {
    my ($e, $path) = @_;
    my $auto_wanted = (defined $e->{user} || defined $e->{group} || defined $e->{mode}) ? 1 : 0;
    my $enabled = defined $e->{apply_meta} ? $e->{apply_meta} : ($apply_meta_enabled || $auto_wanted);

    unless ($enabled) { $log->info("APPLY_META übersprungen (deaktiviert) für Pfad=$path"); return; }

    die "Pfad nicht erlaubt" unless _is_allowed_path($path);
    die "Symlinks werden abgelehnt" if -l $path;

    my $uid = _name2uid($e->{user});
    my $gid = _name2gid($e->{group});

    my $mode;
    if (defined $e->{mode}) {
        my $m = "$e->{mode}";
        $m =~ s/^0+//;
        die "Ungültiger Modus: $e->{mode}" unless $m =~ /^[0-7]{3,4}$/;
        $mode = oct($m);
    }

    if (defined $uid || defined $gid) {
        my $u = defined($uid) ? $uid : -1;
        my $g = defined($gid) ? $gid : -1;
        chown($u, $g, $path) or die "chown fehlgeschlagen: $!";
    }
    chmod($mode, $path) if defined $mode;
}

# --- Backup-Verzeichnis ---
sub _backup_dir_for {
    my ($name) = @_;
    my $sub = $name;
    $sub =~ s{[^A-Za-z0-9._-]+}{_}g;
    return "$backupRoot/$sub";
}

# --- Systemctl mit Timeout ---
sub _systemctl_with_timeout {
    my ($timeout, @cmd) = @_;
    $timeout = 30 unless defined $timeout && $timeout =~ /^\d+$/;

    my $pid = fork();
    die "fork fehlgeschlagen: $!" unless defined $pid;

    if ($pid == 0) {
        # Child-Prozess
        open STDIN, '<', '/dev/null';
        exec @cmd;
        exit 127;
    }

    # Eltern-Prozess
    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; kill 9, $pid; };
    alarm $timeout;
    waitpid($pid, 0);
    alarm 0;

    if ($timed_out) {
        $log->warn("systemctl-Timeout nach ${timeout}s: @cmd");
        return -1;
    }

    if (($? & 127) > 0) {
        my $sig = $? & 127;
        $log->warn("systemctl mit Signal $sig beendet: @cmd");
        return 128 + $sig;
    }

    return $? >> 8;
}

# --- Konfigurations-Mapping ---
my %cfgmap;

sub _derive_actions {
    my ($entry) = @_;
    my %actions;

    if (ref($entry->{actions}) eq 'HASH') {
        while (my ($k, $v) = each %{$entry->{actions}}) { $actions{$k} = (ref($v) eq 'ARRAY') ? [@$v] : []; }
        return \%actions;
    }
    if (ref($entry->{commands}) eq 'HASH') {
        while (my ($k, $v) = each %{$entry->{commands}}) { $actions{$k} = (ref($v) eq 'ARRAY') ? [@$v] : []; }
        return \%actions;
    }
    if (ref($entry->{command_args}) eq 'HASH') {
        my @tokens = ref($entry->{commands}) eq 'ARRAY' ? @{$entry->{commands}} : keys %{$entry->{command_args}};
        for my $t (@tokens) { my $arr = $entry->{command_args}{$t}; $actions{$t} = (ref($arr) eq 'ARRAY') ? [@$arr] : []; }
        return \%actions;
    }
    if (ref($entry->{commands}) eq 'ARRAY' && grep { $_ eq 'run' } @{$entry->{commands}}) {
        $actions{run} = [];
    }
    return \%actions;
}

sub _rebuild_cfgmap_from {
    my ($cfg) = @_;
    %cfgmap = ();
    while (my ($name, $entry) = each %{$cfg}) {
        next if !defined $name || $name =~ m{[/\\]} || $name =~ m{\.\.};
        my $actions = _derive_actions($entry);
        $cfgmap{$name} = {
            %$entry,
            id         => $name,
            service    => $entry->{service}  // $name,
            category   => $entry->{category} // 'uncategorized',
            path       => $entry->{path},
            actions    => $actions,
            backup_dir => _backup_dir_for($name),
        };
    }
}
_rebuild_cfgmap_from($configs);

$log->info(sprintf('START version=%s umask=%04o path_guard=%s apply_meta=%d',
    $VERSION, _cur_umask(), $path_guard, $apply_meta_enabled ? 1 : 0));

# --- Atomares Schreiben ---
sub write_atomic {
    my ($path, $bytes) = @_;
    my $dir = dirname($path);

    my ($fh, $tmp) = tempfile('.tmp_XXXXXX', DIR => $dir, UNLINK => 0);
    binmode($fh, ':raw') or die "binmode fehlgeschlagen: $!";
    print {$fh} $bytes or die "Schreiben fehlgeschlagen: $!";
    eval { $fh->flush() if $fh->can('flush'); 1 };
    eval { $fh->sync()  if $fh->can('sync');  1 };
    close $fh or die "Schließen fehlgeschlagen: $!";

    my $mode = 0666 & ~_cur_umask();
    chmod $mode, $tmp or die "chmod($tmp) fehlgeschlagen: $!";

    rename $tmp, $path or die "Umbenennen fehlgeschlagen: $!";
    _fsync_dir($path);
    return 'atomic';
}

sub safe_write_file {
    my ($path, $bytes) = @_;
    my $method = 'atomic';
    my $ok = eval { write_atomic($path, $bytes); 1 };
    if (!$ok) {
        $method = 'plain';
        open my $fh, '>:raw', $path or die "Öffnen fehlgeschlagen: $!";
        print {$fh} $bytes or die "Schreiben fehlgeschlagen: $!";
        close $fh or die "Schließen fehlgeschlagen: $!";
    }
    return $method;
}

# ==================================================
# REQUEST-HELFER & ACCESS-CONTROL
# ==================================================

# --- Request-Metadaten ---
sub _req_meta {
    my ($c) = @_;
    return {
        req_id => $c->stash('req_id') // '',
        ip     => $c->stash('client_ip') // '',
        method => $c->req->method // '',
        path   => $c->req->url->path->to_string // '',
    };
}

sub _fmt_req {
    my ($c) = @_;
    my $m = _req_meta($c);
    return sprintf('req_id=%s ip=%s %s %s', $m->{req_id}, $m->{ip}, $m->{method}, $m->{path});
}

# --- Client-IP ---
my %TRUSTED = map { $_ => 1 } (ref($global->{trusted_proxies}) eq 'ARRAY' ? @{$global->{trusted_proxies}} : ());

sub _client_ip {
    my ($c) = @_;
    my $rip = $c->tx->remote_address // '';
    if ($TRUSTED{$rip}) {
        my $xff = $c->req->headers->header('X-Forwarded-For') // '';
        if ($xff) {
            my @ips = map { s/^\s+|\s+$//gr } split /,/, $xff;
            return $ips[0] // $rip;
        }
    }
    return $rip;
}

# --- CORS ---
my %ALLOW_ORIGIN = map { $_ => 1 } (ref($global->{allow_origins}) eq 'ARRAY' ? @{$global->{allow_origins}} : ());

app->hook(before_dispatch => sub {
    my $c = shift;
    $c->stash(req_id => sprintf('%x-%x', int(time()*1000), $$));
    $c->stash(t0     => time());
    $c->stash(client_ip => _client_ip($c));

    my $origin = $c->req->headers->origin // '*';
    if (%ALLOW_ORIGIN) {
        $c->res->headers->header('Access-Control-Allow-Origin' => ($ALLOW_ORIGIN{$origin} ? $origin : 'null'));
    } else {
        $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
    }
    $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS');
    $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, X-API-Token, Authorization');
    $c->res->headers->header('Access-Control-Max-Age'       => '86400');

    $log->info(sprintf('REQUEST %s', _fmt_req($c)));
    return $c->render(text => '', status => 204) if $c->req->method eq 'OPTIONS';

    # IP-ACL
    if ($allowed_ips && @{$allowed_ips}) {
        my $rip = $c->stash('client_ip') // '';
        unless (Net::CIDR::cidrlookup($rip, @{$allowed_ips})) {
            $log->info(sprintf('REQUEST %s -> 403 Forbidden', _fmt_req($c)));
            return $c->render(status => 403, json => { ok=>0, error => 'Forbidden' });
        }
    }

    # Token-Auth
    if (defined $api_token && length $api_token) {
        my $hdr     = $c->req->headers->header('X-API-Token') // '';
        my $auth    = $c->req->headers->authorization // '';
        my $bearer  = $auth =~ /^Bearer\s+(.+)/i ? $1 : '';
        my $token   = $hdr || $bearer;
        unless ($token eq $api_token) {
            $log->info(sprintf('REQUEST %s -> 401 Unauthorized', _fmt_req($c)));
            return $c->render(status => 401, json => { ok=>0, error => 'Unauthorized' });
        }
    }
});

app->hook(after_dispatch => sub {
    my $c = shift;
    my $t0 = $c->stash('t0') // time();
    my $dt = time() - $t0;
    my $code = $c->res->code // 200;
    $log->info(sprintf('RESPONSE %s status=%d time=%.3fs', _fmt_req($c), $code, $dt));
});

# ==================================================
# ROUTES
# ==================================================

# --- Root ---
get '/' => sub { shift->render(json => { ok=>1, name=>'config-manager', version=>$VERSION }) };

# --- Konfigurationen auflisten ---
get '/configs' => sub {
    my $c = shift;
    my @list;
    for my $name (sort keys %cfgmap) {
        my $e = $cfgmap{$name};
        my $filename = basename($e->{path});
        my ($ext) = $filename =~ /\.([^.]+)$/;
        my @tokens  = sort keys %{$e->{actions}//{}};
        push @list, {
            id=>$name, filename=>$filename, filetype=>lc($ext // 'txt'),
            category=>$e->{category}, actions=>\@tokens
        };
    }
    $c->render(json => { ok=>1, configs => \@list });
};

# --- Konfiguration lesen ---
get '/config/*name' => sub {
    my $c = shift;
    my $name = $c->stash('name');
    return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400) if $name =~ m{[/\\]} || $name =~ m{\.\.};
    my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannt: $name"}, status=>404);
    my $p = $e->{path};
    return $c->render(json=>{ok=>0,error=>"Pfad nicht erlaubt"}, status=>400) unless _is_allowed_path($p);
    return $c->render(json=>{ok=>0,error=>"Datei fehlt: $p"}, status=>404) unless -f $p;

    open my $fh, "<:raw", $p or return $c->render(json=>{ok=>0,error=>"Lesefehler: $!"}, status=>500);
    my $data = do { local $/; <$fh> }; close $fh;
    $c->res->headers->content_type('application/octet-stream');
    $c->render(data => $data);
};

# --- Konfiguration schreiben ---
post '/config/*name' => sub {
    my $c = shift;
    my $name = $c->stash('name');
    return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400) if $name =~ m{[/\\]};
    my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannt: $name"}, status=>404);
    my $path = $e->{path};
    return $c->render(json=>{ok=>0,error=>"Pfad nicht erlaubt"}, status=>400) unless _is_allowed_path($path);

    my $content = $c->req->body // '';
    if (($c->req->headers->content_type // '') =~ m{application/json}i) {
        my $j = eval { $c->req->json };
        if (!$@ && ref($j) eq 'HASH' && exists $j->{content}) { $content = $j->{content} // ''; }
    }

    my $bdir = $e->{backup_dir};
    unless (-d $bdir) {
        if ($auto_create_backups) { mkdir $bdir; }
        unless (-d $bdir) { return $c->render(json=>{ok=>0,error=>"Backup-Verzeichnis fehlt"}, status=>500); }
    }

    if (-f $path) {
        my $ts = localtime->strftime('%Y%m%d_%H%M%S');
        my $bfile = "$bdir/".basename($path).".bak.$ts";
        copy($path, $bfile);
        my @b = sort { $b cmp $a } grep { defined } glob("$bdir/".basename($path).".bak.*");
        if (@b > $maxBackups) { unlink @b[$maxBackups..$#b]; }
    }

    my $method;
    eval { $method = safe_write_file($path, $content); 1 } or return $c->render(json=>{ok=>0,error=>"Schreibfehler: $@"}, status=>500);

    my $meta_wanted = defined $e->{apply_meta} ? $e->{apply_meta}
                    : ($apply_meta_enabled || defined($e->{user}) || defined($e->{group}) || defined($e->{mode}));

    eval { _apply_meta($e, $path); 1 } or $log->warn("Fehler bei apply_meta: $@");

    my $applied_mode = _mode_str($path);
    my ($uid,$gid)   = ((stat($path))[4], (stat($path))[5]);

    $c->render(json => {
        ok=>1,
        saved => $name,
        path => $path,
        method => $method,
        requested => { user=>$e->{user}, group=>$e->{group}, mode=>$e->{mode}, apply_meta => ($meta_wanted ? JSON::MaybeXS::true : JSON::MaybeXS::false) },
        applied   => { uid=>$uid, gid=>$gid, mode=>$applied_mode }
    });
};

# --- Backups auflisten ---
get '/backups/*name' => sub {
    my $c = shift;
    my $name = $c->stash('name');
    return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400) if $name =~ m{[/\\]} || $name =~ m{\.\.};
    my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
    my $bdir = $e->{backup_dir};
    return $c->render(json=>{ok=>0,error=>"Backup-Verzeichnis fehlt: $bdir"}, status=>500) unless -d $bdir;
    my $base = basename($e->{path});
    my @files = sort { $b cmp $a } grep { defined } glob("$bdir/$base.bak.*");
    @files = map { s{^\Q$bdir\E/}{}r } @files;
    $c->render(json => { ok=>1, backups => \@files });
};

# --- Backup-Inhalt lesen ---
get '/backupcontent/*name/*filename' => sub {
    my $c = shift;
    my $name = $c->stash('name');
    my $filename = $c->stash('filename');
    return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
        if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};
    my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
    my $bdir = $e->{backup_dir};
    my $base = basename($e->{path});
    return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
        unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}$/;

    my $file = "$bdir/$filename";
    return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $file;
    open my $fh, '<:raw', $file or return $c->render(json=>{ok=>0,error=>"Backup-Datei konnte nicht geöffnet werden: $!"}, status=>500);
    my $content = do { local $/; <$fh> }; close $fh;
    $c->render(json => { ok=>1, content => $content });
};

# --- Backup wiederherstellen ---
post '/restore/*name/*filename' => sub {
    my $c = shift;
    my $name = $c->stash('name');
    my $filename = $c->stash('filename');
    return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
        if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};
    my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
    my $base = basename($e->{path});
    my $bdir = $e->{backup_dir};
    return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
        unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}$/;

    my $src  = "$bdir/$filename";
    my $dest = $e->{path};
    return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $src;
    return $c->render(json=>{ok=>0,error=>'Pfad nicht erlaubt'}, status=>400) unless _is_allowed_path($dest);

    copy($src, $dest) or return $c->render(json=>{ok=>0,error=>"Wiederherstellung fehlgeschlagen: $!"}, status=>500);
    eval { _apply_meta($e, $dest); 1 } or $log->warn("Fehler bei apply_meta: $@");

    my $applied_mode = _mode_str($dest);
    my ($uid,$gid)   = ((stat($dest))[4], (stat($dest))[5]);
    my $meta_wanted = defined $e->{apply_meta} ? $e->{apply_meta}
                    : ($apply_meta_enabled || defined($e->{user}) || defined($e->{group}) || defined($e->{mode}));

    $c->render(json => {
        ok=>1,
        restored  => $name, from => $filename,
        requested => { user=>$e->{user}, group=>$e->{group}, mode=>$e->{mode}, apply_meta => ($meta_wanted ? JSON::MaybeXS::true : JSON::MaybeXS::false) },
        applied   => { uid=>$uid, gid=>$gid, mode=>$applied_mode }
    });
};

# --- Aktion ausführen ---
post '/action/*name/*cmd' => sub {
    my $c = shift;
    my ($name, $cmd) = ($c->stash('name'), $c->stash('cmd'));
    return $c->render(json=>{ok=>0,error=>'Ungültige Anfrage'}, status=>400) if !defined $name || $name =~ m{[/\\]};

    my $tool  = $SYSTEMCTL;
    my @ctl = ($tool, shellwords($SYSTEMCTL_FLAGS // ''));

    if ($cmd eq 'daemon-reload') {
        my $rc = _systemctl_with_timeout(20, @ctl, 'daemon-reload');
        return $rc == 0 ? $c->render(json=>{ok=>1}) : $c->render(json=>{ok=>0,error=>"Rückgabewert=$rc"}, status=>500);
    }

    my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannt"}, status=>404);
    my $svc = $e->{service} // $name;
    my $actmap = $e->{actions};

    return $c->render(json=>{ok=>0,error=>'Aktion nicht erlaubt'}, status=>400) unless ref($actmap) eq 'HASH' && exists $actmap->{$cmd};

    my @extra = @{$actmap->{$cmd}};
    for (@extra) { return $c->render(json=>{ok=>0,error=>"Ungültiges Argument"}, status=>400) unless /^[A-Za-z0-9._:+@\/=\-,]+$/; }

    # Script-Ausführung
    if ($svc =~ m{^(bash|sh|perl|exec):(/.+)$}) {
        my ($runner, $script) = ($1, $2);
        return $c->render(json=>{ok=>0,error=>"Skript nicht gefunden: $script"}, status=>404) unless -f $script;

        if ($runner eq 'exec' && $script =~ m{/systemctl$}) {
            return $c->render(json=>{ok=>0,error=>'Subcommand verboten'}, status=>400) if ($extra[0]//'') =~ /^(poweroff|reboot|halt)$/;
        }

        my @argv =
            $runner eq 'perl' ? ('/usr/bin/perl', $script, @extra) :
            $runner eq 'bash' ? ('/bin/bash', $script, @extra) :
            ($script, @extra);

        my ($script_dir) = $script =~ m{^(.+)/[^/]+$};
        my $cwd_prev = getcwd();
        chdir $script_dir if defined $script_dir;

        my $start = time();
        my ($out_r, $pid, $buf_out, $buf_err) = (undef, undef, '', '');
        my $err_h = gensym;

        eval {
            $pid = open3(undef, $out_r, $err_h, @argv);
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 60;

            my $child_exited = 0;
            while (1) {
                if (!$child_exited) {
                    my $wp = waitpid($pid, WNOHANG);
                    $child_exited = 1 if $wp == $pid || $wp == -1;
                }
                my $rin = '';
                vec($rin, fileno($out_r), 1) = 1 if $out_r;
                vec($rin, fileno($err_h), 1) = 1 if $err_h;
                last if $child_exited && $rin eq '';

                if (select(my $rout=$rin, undef, undef, 0.1) > 0) {
                    my $tmp;
                    if ($out_r && vec($rout, fileno($out_r), 1)) {
                        sysread($out_r, $tmp, 4096) > 0 ? $buf_out .= $tmp : do { close $out_r; undef $out_r; };
                    }
                    if ($err_h && vec($rout, fileno($err_h), 1)) {
                        sysread($err_h, $tmp, 4096) > 0 ? $buf_err .= $tmp : do { close $err_h; undef $err_h; };
                    }
                }
            }
            alarm 0;
        } or do {
            alarm 0; kill 9, $pid if $pid; waitpid($pid,0) if $pid;
            chdir $cwd_prev;
            return $c->render(json=>{ok=>0,error=>"Skript-Timeout/Fehler"}, status=>500);
        };

        chdir $cwd_prev;
        my $rc = $? >> 8;

        if ($runner eq 'exec' && $script =~ m{/systemctl$} && ($extra[0]//'') eq 'is-active') {
            return $c->render(json=>{ok=>1, status=>($rc==0?'running':'stopped'), rc=>$rc});
        }

        return $c->render(json=>{
            ok => ($rc == 0 || ($script=~/postmulti/ && $rc<=1)) ? 1 : 0,
            rc => $rc, stdout => substr($buf_out,0,10000), stderr => substr($buf_err,0,10000)
        });
    }

    if ($svc eq 'systemctl') {
        return $c->render(json=>{ok=>0,error=>'Verboten'}, status=>400) if $cmd =~ /^(poweroff|reboot|halt)$/;
        my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS//''), $cmd);
        return $rc == 0 ? $c->render(json=>{ok=>1}) : $c->render(json=>{ok=>0,error=>"Rückgabewert=$rc"}, status=>500);
    }

    my $run = sub { return _systemctl_with_timeout(30, $SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS//''), $_[0], $svc) == 0; };

    if ($cmd eq 'status' || $cmd eq 'stop_start' || $cmd eq 'restart' || $cmd eq 'reload') {
        if ($cmd eq 'stop_start') { $run->('stop'); $run->('start'); }
        elsif ($cmd eq 'restart') { $run->('restart'); }
        elsif ($cmd eq 'reload') {
            my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS//''), 'is-active', $svc) == 0;
            $run->('reload') if $active;
        }

        my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS//''), 'is-active', $svc) == 0;
        return $c->render(json=>{ok=>1, action=>$cmd, status=>($active?'running':'stopped')});
    }

    if ($run->($cmd)) {
        return $c->render(json=>{ok=>1, action=>$cmd, status=>'ok'});
    } else {
        return $c->render(json=>{ok=>0, error=>"Fehler bei $cmd"}, status=>500);
    }
};

# --- Raw configs ---
get '/raw/configs' => sub { shift->render(data => read_all($configsfile)); };

post '/raw/configs' => sub {
    my $c = shift;
    my $raw = $c->req->body // '';
    eval { decode_json($raw); 1 } or return $c->render(json=>{ok=>0,error=>'Ungültiges JSON'}, status=>400);
    safe_write_file($configsfile, $raw);
    _rebuild_cfgmap_from(decode_json($raw));
    $c->render(json=>{ok=>1,reload=>1});
};

post '/raw/configs/reload' => sub {
    my $c = shift;
    my $cfg = eval { decode_json(read_all($configsfile)) } or return $c->render(json=>{ok=>0,error=>'JSON-Fehler'}, status=>500);
    _rebuild_cfgmap_from($cfg);
    $c->render(json=>{ok=>1,reloaded=>1});
};

del '/raw/configs/:name' => sub {
    my $c = shift;
    my $name = $c->stash('name');
    my $cfg = decode_json(read_all($configsfile));
    return $c->render(status=>404, json=>{ok=>0}) unless delete $cfg->{$name};
    safe_write_file($configsfile, encode_json($cfg));
    _rebuild_cfgmap_from($cfg);
    $c->render(json=>{ok=>1});
};

# --- Health-Check ---
get '/health' => sub { shift->render(json=>{ok=>1, status=>'ok'}); };

# --- 404 ---
any '/*whatever' => sub { shift->render(json=>{ok=>0,error=>'404 Not Found'}, status=>404); };

# ---------------- Server starten ----------------
my $listen_url = "http://$global->{listen}";
if ($global->{ssl_enable}) {
    $listen_url = "https://$global->{listen}?cert=$global->{ssl_cert_file}&key=$global->{ssl_key_file}";
}
app->start('daemon','-l',$listen_url);

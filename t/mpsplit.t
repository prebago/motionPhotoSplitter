#!/usr/bin/env perl
# Run from the project root: prove t/
# End-to-end tests use $MPSPLIT_SAMPLES (default Samples/) and are skipped
# without motion photos; special cases are generated from the first sample.

use strict;
use warnings;
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Image::ExifTool;
use Test::More;
use Time::Local ();

my $SCRIPT  = "$Bin/../mpsplit";
my $SAMPLES = $ENV{MPSPLIT_SAMPLES} // "$Bin/../Samples";

require $SCRIPT;    # subs only, main() does not run

subtest output_paths => sub {
    is_deeply [ output_paths('a/b.MP.jpg') ],       [ 'a/b.jpg', 'a/b.mp4' ];
    is_deeply [ output_paths('a/b c.mp.JPG') ],     [ 'a/b c.jpg', 'a/b c.mp4' ];
    is_deeply [ output_paths('a/b.MP.jpg', 'o') ],  [ 'o/b.jpg', 'o/b.mp4' ];
    is_deeply [ output_paths('a/b.jpg') ],          [], 'not *.MP.jpg';
};

subtest locate_video => sub {
    my $dir = sub { +{ ContainerDirectory => [ map { +{ Item => $_ } } @_ ] } };
    my $v2 = $dir->({ Semantic => 'Primary', Mime => 'image/jpeg' },
                    { Semantic => 'GainMap', Mime => 'image/jpeg', Length => 300 },
                    { Semantic => 'MotionPhoto', Mime => 'video/mp4', Length => 1000, Padding => 8 });
    is_deeply [ locate_video(5000, $v2) ], [ 3992, 1000 ], 'V2 with padding';
    is_deeply [ locate_video(5000, $dir->({ Semantic => 'MotionPhoto', Length => 1000 })) ],
        [ 4000, 1000 ], 'V2 without Padding field';
    is_deeply [ locate_video(5000, { MicroVideoOffset => 1200 }) ], [ 3800, 1200 ], 'V1';
    is_deeply [ locate_video(5000, {}) ], [], 'no motion metadata';
    ok !eval { locate_video(5000, $dir->({ Semantic => 'MotionPhoto', Length => 0 })); 1 },
        'V2 with zero length is an error';
    ok !eval { locate_video(5000, { MicroVideoOffset => 'x' }); 1 }, 'V1 with invalid offset is an error';
};

subtest container_items => sub {
    my $item = { Semantic => 'GainMap', Mime => 'image/jpeg', Length => 300, URI => 'gm', Label => 'x' };
    is_deeply [ container_items({ ContainerDirectory => [ { Item => $item } ] }) ], [ $item ],
        'all fields kept, none added';
    is_deeply [ container_items({}) ], [], 'no directory';
};

subtest helpers => sub {
    my $mp4 = "xxxx\0\0\0\x18ftypisom";
    ok  is_mp4_at(\$mp4, 4), 'ftyp found';
    ok !is_mp4_at(\$mp4, 0), 'ftyp not at 0';
    ok !is_mp4_at(\$mp4, -1), 'negative offset';
    is positive_int('12'), 12;
    ok !defined positive_int($_), "positive_int rejects '$_'" for '0', '-1', '1.5', 'x', '';
};

subtest write_outputs_all_or_nothing => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $src = "$dir/src";
    write_file($src, 'source');

    ok !eval { write_outputs($src, [ "$dir/a", \'A' ], [ "$dir/missing/b", \'B' ]); 1 },
        'fails if one output cannot be written';
    ok !-e "$dir/a", 'no partial output left';

    mkdir "$dir/c";    # existing target: its rename is refused
    ok !eval { write_outputs($src, [ "$dir/a", \'A' ], [ "$dir/c", \'C' ]); 1 },
        'fails if one output cannot be renamed into place';
    ok !-e "$dir/a", 'output renamed before the failure is removed again';
    is_deeply [ dir_entries($dir) ], [ 'c', 'src' ], 'no temp files left';

    ok eval { write_outputs($src, [ "$dir/a", \'A' ], [ "$dir/b", \'B' ]); 1 }, 'succeeds';
    is read_file("$dir/b"), 'B', 'content written';
    is +(stat "$dir/a")[9], (stat $src)[9], 'mtime copied';
};

my @sources = -d $SAMPLES ? find_motion_photos($SAMPLES) : ();
my @motion  = grep { tags($_, 'MotionPhotoVideo')->{MotionPhotoVideo} } @sources;

SKIP: {
    skip "no motion photos in $SAMPLES", 1 unless @motion;

    subtest samples => sub {
        my $out = tempdir(CLEANUP => 1);
        my ($exit, $log) = run('-o', $out, $SAMPLES);
        is $exit, 0, 'exit 0 on samples';
        like $log, qr/split: ${\ scalar @motion} /, 'all motion photos split';

        for my $src (@motion) {
            subtest basename_of($src) => sub { check_outputs($src, $out) };
        }

        ($exit, $log) = run('-o', $out, $SAMPLES);
        is $exit, 0, 'rerun exits 0';
        like $log, qr/split: 0 .*skipped \(exists\): ${\ scalar @motion} /, 'rerun skips everything';
    };

    my $sample = $motion[0];
    my $data   = read_file($sample);

    subtest single_file_argument => sub {
        my $out = tempdir(CLEANUP => 1);
        my ($exit, $log) = run('-o', $out, $sample);
        is $exit, 0, 'exit 0';
        like $log, qr/split: 1 /, 'split';
    };

    subtest damaged_files_are_errors => sub {
        my $dir = tempdir(CLEANUP => 1);
        write_file("$dir/truncated.MP.jpg", substr($data, 0, 500_000));
        write_file("$dir/zeros.MP.jpg", "\0" x 100);
        write_file("$dir/text.MP.jpg", "not an image\n");
        my ($exit, $log) = run($dir);
        is $exit, 1, 'exit 1';
        like $log, qr/split: 0 .*errors: 3/, 'all three counted as errors';
        like $log, qr/damaged JPEG/, 'truncated file reported as damaged';
    };

    subtest output_name_collision => sub {
        my $dir = tempdir(CLEANUP => 1);
        make_path("$dir/in/a", "$dir/in/b");
        write_file("$dir/in/$_/same.MP.jpg", $data) for qw(a b);
        my ($exit, $log) = run('-o', "$dir/out", "$dir/in");
        is $exit, 1, 'exit 1';
        like $log, qr/output name collides with/, 'collision reported';
        like $log, qr/split: 1 .*errors: 1/, 'first split, second is an error';
    };

    subtest v1_format => sub {
        my $dir = tempdir(CLEANUP => 1);
        my $video = embedded_video($sample);
        my $et = new_et();
        $et->SetNewValue($_) for qw(
            XMP-GContainer:ContainerDirectory XMP-GCamera:MotionPhoto
            XMP-GCamera:MotionPhotoVersion XMP-GCamera:MotionPhotoPresentationTimestampUs);
        $et->SetNewValue('XMP-GCamera:MicroVideo'        => 1);
        $et->SetNewValue('XMP-GCamera:MicroVideoVersion' => 1);
        $et->SetNewValue('XMP-GCamera:MicroVideoOffset'  => length $video);
        my $v1 = write_info($et, \$data, 'create V1 test file');
        write_file("$dir/v1.MP.jpg", $v1);

        my ($exit, $log) = run($dir);
        is $exit, 0, 'exit 0';
        like $log, qr/split: 1 /, 'split';
        ok media_data("$dir/v1.mp4") eq media_data(\$video), 'video media data identical';
        ok !grep({ /^MicroVideo/ } keys %{ tags("$dir/v1.jpg", 'XMP-GCamera:all') }),
            'no MicroVideo tags left';
    };

    subtest missing_video_dates_are_filled_in => sub {
        my $dir = tempdir(CLEANUP => 1);
        my $video = embedded_video($sample);
        my $et = new_et();
        $et->SetNewValue("QuickTime:$_" => '0000:00:00 00:00:00')
            for qw(CreateDate ModifyDate TrackCreateDate TrackModifyDate MediaCreateDate MediaModifyDate);
        my $nodate = write_info($et, \$video, 'create test video');
        is length($nodate // ''), length $video, 'test video keeps its size' or return;
        write_file("$dir/nodate.MP.jpg", substr($data, 0, length($data) - length $video) . $nodate);

        is tags(\$nodate, 'QuickTime:CreateDate')->{CreateDate}, '0000:00:00 00:00:00',
            'test video has no CreateDate';

        my ($exit) = run($dir);
        is $exit, 0, 'exit 0';
        # QuickTime: UTC, whole seconds. Photo: local time + offset.
        my $photo = tags($sample, 'Composite:SubSecDateTimeOriginal')->{SubSecDateTimeOriginal};
        my $video = tags("$dir/nodate.mp4", 'QuickTime:CreateDate')->{CreateDate};
        is epoch($video), int epoch($photo), 'CreateDate set from photo (same instant)';
    };
}

my ($exit) = run('/nonexistent/path');
is $exit, 1, 'missing path exits 1';
($exit) = run();
is $exit, 2, 'no arguments exits 2';
($exit) = run('-x');
is $exit, 2, 'unknown option exits 2';
my $log;
($exit, $log) = run('--help');
ok $exit == 0 && $log =~ /^Usage:/, '--help prints only the usage';
($exit, $log) = run('--version');
ok $exit == 0 && $log =~ /^mpsplit \d/, '--version';

done_testing;

sub check_outputs {
    my ($src, $out) = @_;
    my ($jpg, $mp4) = output_paths($src, $out);
    ok -f $jpg && -f $mp4, 'both outputs exist' or return;

    my $s = tags($src, qw(IFD0:Make ExifIFD:DateTimeOriginal Composite:GPSPosition MPImage2));
    my $p = tags($jpg, qw(FileType Error IFD0:Make ExifIFD:DateTimeOriginal Composite:GPSPosition
                          XMP-GCamera:all MotionPhotoVideo MPImage2 JUMBF:all));
    is $p->{FileType}, 'JPEG', 'photo is a JPEG';
    ok !$p->{Error}, 'photo has no ExifTool error';
    is $p->{$_}, $s->{$_}, "photo keeps $_" for qw(Make DateTimeOriginal GPSPosition);
    ok !grep({ /^(MotionPhoto(Version|PresentationTimestampUs)?|MicroVideo\w*)$/ } keys %$p),
        'no motion-photo XMP tags left';
    ok !$p->{MotionPhotoVideo}, 'no video trailer left';
    ok !grep({ /^JUMD/ } keys %$p), 'no C2PA manifest left';

    my @kept = grep { $_->{Semantic} ne 'MotionPhoto' } directory($src);
    my @expected = (grep { $_->{Semantic} ne 'Primary' } @kept) ? @kept : ();
    is_deeply [ directory($jpg) ], \@expected,
        @expected ? 'Container keeps non-video items unchanged' : 'Container directory removed';
    if ($s->{MPImage2}) {
        ok ${ $p->{MPImage2} // \'' } eq ${ $s->{MPImage2} }, 'gain map image byte-identical';
    }

    ok media_data($mp4) eq media_data(\embedded_video($src)), 'video media data identical';
    my $v = tags($mp4, qw(Keys:Make Keys:GPSCoordinates Keys:CreationDate));
    is $v->{Make}, $s->{Make}, 'video has Make';
    ok $v->{GPSCoordinates}, 'video has GPS' if $s->{GPSPosition};
    ok $v->{CreationDate}, 'video has CreationDate';

    is +(stat $jpg)[9], (stat $src)[9], 'photo mtime copied';
    is +(stat $mp4)[9], (stat $src)[9], 'video mtime copied';
}

sub directory { container_items(read_tags($_[0], 'XMP-GContainer:ContainerDirectory')) }

# Extracted by ExifTool, independently of the script.
sub embedded_video { ${ tags($_[0], 'MotionPhotoVideo')->{MotionPhotoVideo} } }

sub media_data {
    my $src = shift;
    my $t = tags($src, qw(MediaDataOffset MediaDataSize));
    my $data = ref $src ? $$src : read_file($src);
    return substr($data, $t->{MediaDataOffset}, $t->{MediaDataSize});
}

sub tags {
    my ($src, @tags) = @_;
    my $et = Image::ExifTool->new;
    $et->Options(Binary => 1, Duplicates => 0, PrintConv => 0, List => 1);
    return plain_keys($et->ImageInfo($src, \@tags));
}

# "YYYY:MM:DD HH:MM:SS[.sss][+-HH:MM]" -> epoch seconds; no offset = UTC.
sub epoch {
    my ($y, $mo, $d, $h, $mi, $s, $frac, $sign, $oh, $om) =
        $_[0] =~ /^(\d+):(\d+):(\d+) (\d+):(\d+):(\d+)(\.\d+)?(?:([+-])(\d+):(\d+))?/ or return;
    my $t = Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y) + ($frac // 0);
    $t -= ($sign eq '+' ? 1 : -1) * ($oh * 3600 + $om * 60) if $sign;
    return $t;
}

sub dir_entries {
    opendir(my $dh, $_[0]) or die "opendir: $!";
    return sort grep { !/^\./ } readdir $dh;
}

sub run {
    my @args = @_;
    my $pid = open my $fh, '-|';
    defined $pid or die "fork: $!";
    if (!$pid) {
        open STDERR, '>&', \*STDOUT;
        exec $^X, $SCRIPT, @args or die "exec: $!";
    }
    local $/;
    my $log = <$fh> // '';
    close $fh;
    return ($? >> 8, $log);
}

sub basename_of { (my $b = shift) =~ s{.*/}{}; $b }

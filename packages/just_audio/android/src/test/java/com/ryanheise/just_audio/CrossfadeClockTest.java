package com.ryanheise.just_audio;

/** Regression for a track clock running increasingly ahead after consecutive crossfades. */
public final class CrossfadeClockTest {
    public static void main(String[] args) {
        CrossfadeClock clock = new CrossfadeClock();
        clock.onStream(24_000_000, 7_500_000);
        assert clock.positionUs(23_900_000) == 23_900_000 : "correction applied before the new stream";
        assert clock.positionUs(24_100_000) == 31_600_000;

        clock.onStream(48_000_000, 7_500_000);
        assert clock.positionUs(47_900_000) == 47_900_000 : "queued anchor retained an absorbed correction";
        assert clock.positionUs(48_100_000) == 55_600_000 : "previous crossfade counted twice";

        clock.onStream(72_000_000, 3_500_000);
        assert clock.positionUs(72_100_000) == 75_600_000 : "unequal overlaps accumulated";
        clock.onStream(96_000_000, 0);
        assert clock.positionUs(95_900_000) == 95_900_000 : "ordinary stream retained the old correction while draining";
        assert clock.positionUs(96_100_000) == 96_100_000 : "ordinary track inherited a crossfade correction";

        clock.clear();
        assert clock.positionUs(25_000_000) == 25_000_000 : "seek retained the old clock";
        clock.onStream(30_000_000, 1_250_000);
        assert clock.positionUs(30_100_000) == 31_350_000 : "crossfade after a seek failed";
        clock.onStream(54_000_000, 0); // Input timestamps include 6 s supplied by the independent ring drain.
        clock.onStream(54_000_000, -6_000_000);
        assert clock.positionUs(54_100_000) == 48_100_000 : "ring carrier time leaked into the next track clock";
        System.out.println("Crossfade clock: consecutive and unequal overlaps, queued anchors, ordinary tracks and seek reset passed");
    }
}
